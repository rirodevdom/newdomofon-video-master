#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path
import re


MARKER = "NEWDOMOFON_SERVER_MEDIA_COMPAT_V1"
IMPORT_BLOCK = f'''# {MARKER}
from newdomofon_media_compat import (
    NewDomofonCompatibilityError,
    apply_smartyard_response_compat,
    build_camera_export_url,
    fetch_camera_ranges,
)
'''

AFTER_REQUEST_BLOCK = f'''
# {MARKER}: CORS and managed-token rewriting happen on the server.
@app.after_request
def newdomofon_smartyard_response_compat(response):
    return apply_smartyard_response_compat(response, request)

'''

RANGES_BLOCK = f'''@app.route('/api/cctv/ranges', methods=['POST'])
async def cctv_ranges():
    # {MARKER}
    global response
    phone = access_verification(request.headers)
    request_data = json_verification(request)
    camera_id = request_data['cameraId']

    user_row = db.session.query(Users.videotoken).filter_by(userphone=phone).first()
    db.session.remove()
    camera_rows = [
        row._asdict()
        for row in db.session.query(
            Devices.device_uuid,
            Devices.url,
            Devices.server_id,
        ).filter_by(device_id=camera_id, is_active=True).all()
    ]
    db.session.remove()

    if not user_row or not camera_rows:
        response = {{
            'code': 404,
            'name': 'Camera not found',
            'message': 'Камера не найдена или недоступна',
        }}
        return make_response(jsonify(response), 404)

    camera = camera_rows[0]
    stream = str(camera['device_uuid'])
    camera_url = str(camera['url']).rstrip('/') + '/' + stream

    try:
        data = fetch_camera_ranges(
            camera_url=camera_url,
            existing_token=user_row[0],
            camera_id=camera_id,
            stream=stream,
        )
    except NewDomofonCompatibilityError as error:
        response = {{
            'code': error.status_code,
            'name': 'Video archive error',
            'message': str(error),
        }}
        return make_response(jsonify(response), error.status_code)

    response = {{'code': 200, 'name': 'OK', 'message': 'Хорошо', 'data': data}}
    return jsonify(response)

'''

PREPARE_BLOCK = f'''@app.route('/api/cctv/recPrepare', methods=['POST'])
async def cctv_recPrepare():
    # {MARKER}
    global response
    phone = access_verification(request.headers)
    request_data = json_verification(request)
    camera_id = request_data['id']

    camera_rows = [
        row._asdict()
        for row in db.session.query(
            Devices.device_uuid,
            Devices.url,
            Devices.title,
        ).filter_by(device_id=camera_id, is_active=True).all()
    ]
    db.session.remove()
    user_rows = [
        row._asdict()
        for row in db.session.query(
            Users.videotoken,
            Users.uid,
        ).filter_by(userphone=phone).all()
    ]
    db.session.remove()

    if not camera_rows or not user_rows:
        response = {{
            'code': 404,
            'name': 'Camera not found',
            'message': 'Камера не найдена или недоступна',
        }}
        return make_response(jsonify(response), 404)

    camera = camera_rows[0]
    user = user_rows[0]
    stream = str(camera['device_uuid'])
    camera_url = str(camera['url']).rstrip('/') + '/' + stream
    camera_name = str(camera['title'])
    time_from = datetime.datetime.strptime(request_data['from'], '%Y-%m-%d %H:%M:%S')
    time_to = datetime.datetime.strptime(request_data['to'], '%Y-%m-%d %H:%M:%S')

    try:
        url, duration = build_camera_export_url(
            camera_url=camera_url,
            existing_token=user['videotoken'],
            time_from=time_from,
            time_to=time_to,
            camera_id=camera_id,
            stream=stream,
        )
    except NewDomofonCompatibilityError as error:
        response = {{
            'code': error.status_code,
            'name': 'Video export error',
            'message': str(error),
        }}
        return make_response(jsonify(response), error.status_code)

    file_url = (
        camera_name.lower()
        .replace(',', '_')
        .replace('.', '_')
        .replace(' ', '_')
        + '_'
        + time_from.strftime('%H-%M-%S_%m_%d_%Y')
        + '__'
        + time_to.strftime('%H-%M-%S_%m_%d_%Y')
        + '.mp4'
    )
    full_file_url = videoarchivedir + '/' + file_url

    record = Records(
        id=None,
        uid=user['uid'],
        url=url,
        fileurl=file_url,
        rtime=None,
        rdone=False,
    )
    db.session.add(record)
    db.session.commit()
    record_id = record.id
    db.session.remove()

    try:
        with open(full_file_url, 'wb') as output:
            transfer = pycurl.Curl()
            transfer.setopt(transfer.URL, url)
            transfer.setopt(transfer.WRITEDATA, output)
            transfer.setopt(transfer.SSL_VERIFYPEER, 0)
            transfer.setopt(transfer.SSL_VERIFYHOST, 0)
            transfer.setopt(transfer.CONNECTTIMEOUT, 15)
            transfer.setopt(transfer.TIMEOUT, max(60, duration * 4))
            transfer.perform()
            status_code = int(transfer.getinfo(transfer.RESPONSE_CODE))
            transfer.close()
    except Exception:
        status_code = 502

    if status_code == 200:
        db.session.query(Records).filter_by(id=record_id).update({{'rdone': True}})
        db.session.commit()
        db.session.remove()
        response = {{'code': 200, 'name': 'OK', 'message': 'Хорошо', 'data': record_id}}
        return jsonify(response)

    try:
        os.remove(full_file_url)
    except OSError:
        pass
    response = {{
        'code': status_code,
        'name': 'Video export failed',
        'message': 'Не удалось подготовить видеоархив',
    }}
    return make_response(jsonify(response), status_code if 400 <= status_code <= 599 else 502)

'''


def replace_function_block(text: str, function_name: str, replacement: str) -> str:
    match = re.search(
        rf"(?m)^@app\.route\([^\n]+\)\nasync def {re.escape(function_name)}\(\):\n",
        text,
    )
    if not match:
        raise RuntimeError(f"function {function_name} was not found")

    next_route = re.search(r"(?m)^@app\.route\(", text[match.end():])
    if not next_route:
        raise RuntimeError(f"next route after {function_name} was not found")
    end = match.end() + next_route.start()
    return text[:match.start()] + replacement + text[end:]


def patch_text(text: str) -> str:
    if MARKER in text:
        required = (
            "newdomofon_smartyard_response_compat",
            "fetch_camera_ranges(",
            "build_camera_export_url(",
        )
        missing = [item for item in required if item not in text]
        if missing:
            raise RuntimeError(f"incomplete existing compatibility patch: {missing}")
        return text

    import_anchor = "from dotenv import load_dotenv\n"
    if import_anchor not in text:
        raise RuntimeError("dotenv import anchor was not found")
    text = text.replace(import_anchor, import_anchor + IMPORT_BLOCK, 1)

    app_anchor = "app = Flask(__name__)\n"
    if app_anchor not in text:
        raise RuntimeError("Flask app anchor was not found")
    text = text.replace(app_anchor, app_anchor + AFTER_REQUEST_BLOCK, 1)

    text = replace_function_block(text, "cctv_ranges", RANGES_BLOCK)
    text = replace_function_block(text, "cctv_recPrepare", PREPARE_BLOCK)

    for marker in (
        MARKER,
        "apply_smartyard_response_compat",
        "fetch_camera_ranges(",
        "build_camera_export_url(",
    ):
        if marker not in text:
            raise RuntimeError(f"missing result marker: {marker}")
    return text


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Patch AXIOSTV SmartYard-Server for NewDomofon media compatibility."
    )
    parser.add_argument(
        "--target",
        default="/opt/rbt/server/smartyard.py",
        help="Path to the installed SmartYard server module.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Validate compatibility and report whether the file would change.",
    )
    args = parser.parse_args()

    path = Path(args.target).resolve()
    if not path.is_file():
        raise SystemExit(f"SmartYard server source not found: {path}")

    original = path.read_text(encoding="utf-8")
    patched = patch_text(original)
    changed = patched != original

    if not args.check and changed:
        path.write_text(patched, encoding="utf-8")

    print(f"SmartYard server media compatibility: {path}")
    print(f"changed={'true' if changed else 'false'}")
    print(f"check_only={'true' if args.check else 'false'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
