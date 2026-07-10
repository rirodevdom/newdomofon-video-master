# Disk pressure protection

Master does not store video or camera-event payloads, but it can still become unavailable if the filesystem containing PostgreSQL, journald, nginx logs, package cache, or temporary files becomes full.

`newdomofon-video-master-disk-guard.timer` runs independently from the backend once per minute.

## Default behavior

- checks `/`, `/var/lib/postgresql`, and `/var/log/newdomofon-video`;
- enters critical mode below `2 GiB` or `5%` free, whichever is larger;
- leaves critical mode only above `4 GiB` and `10%` free;
- checks free inodes as well as bytes;
- limits and vacuums journald;
- removes only stale project/npm temporary directories;
- optionally runs `apt-get clean` in critical mode;
- never deletes PostgreSQL files or application data;
- writes state to `/run/newdomofon-video/master-disk-state.json`;
- writes the critical marker `/run/newdomofon-video/master-disk-critical`.

While the critical marker exists, the backend remains available for health checks, authentication, reads, live/archive resolution, and SmartYard resolution, but rejects mutating API requests with HTTP `507 Insufficient Storage`. This avoids pushing additional writes into a nearly full PostgreSQL filesystem.

## Installation

```bash
cd /opt/newdomofon-video-master
bash scripts/install-master-disk-guard.sh
systemctl restart newdomofon-video-backend.service
```

The installer applies bounded journald storage. Disable that part only when the host already has a stricter central policy:

```bash
INSTALL_JOURNAL_LIMITS=0 bash scripts/install-master-disk-guard.sh
```

## Recommended environment

```text
MASTER_DISK_GUARD_PATHS=/:/var/lib/postgresql:/var/log/newdomofon-video
MASTER_DISK_MIN_FREE_BYTES=2147483648
MASTER_DISK_MIN_FREE_PERCENT=5
MASTER_DISK_RESUME_FREE_BYTES=4294967296
MASTER_DISK_RESUME_FREE_PERCENT=10
MASTER_DISK_MIN_FREE_INODES_PERCENT=5
MASTER_DISK_RESUME_FREE_INODES_PERCENT=8
MASTER_JOURNAL_MAX_SIZE=512M
MASTER_JOURNAL_MAX_AGE=7d
MASTER_DISK_STALE_TMP_MINUTES=60
MASTER_DISK_APT_CLEAN_ON_CRITICAL=true
```

When PostgreSQL is stored elsewhere, add its real data filesystem to `MASTER_DISK_GUARD_PATHS`.

## Status

```bash
systemctl status newdomofon-video-master-disk-guard.timer --no-pager
systemctl status newdomofon-video-master-disk-guard.service --no-pager
journalctl -u newdomofon-video-master-disk-guard.service -n 200 --no-pager
cat /run/newdomofon-video/master-disk-state.json | jq .
curl -fsS http://127.0.0.1:3000/api/health | jq .
```

## Safe verification

Do not create a large filler file on production. Temporarily set a threshold slightly above the current free space, run the oneshot guard, verify that the marker appears and an administrative write returns 507, then restore the real values and run the guard again.

```bash
systemctl start newdomofon-video-master-disk-guard.service
cat /run/newdomofon-video/master-disk-state.json | jq .
ls -l /run/newdomofon-video/master-disk-critical 2>/dev/null || true
```

## Important limitation

No software guard can repair a PostgreSQL filesystem that is already completely full. Keep PostgreSQL on a dedicated or adequately reserved filesystem, monitor it externally, retain filesystem reserved blocks where appropriate, and alert before the critical watermark.
