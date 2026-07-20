# SmartYard integration: only NewDomofon-controlled components

This project must not require changes on RBT, SmartYard-Server, the original SmartYard-Vue deployment, or any third-party server.

## What NewDomofon can guarantee

NewDomofon master/node provide direct media endpoints for a camera URL returned to a browser:

- `/<stream>/preview.mp4?token=...` — still, silent preview;
- `/<stream>/<unix>-preview.mp4?token=...` — timestamp preview;
- `/<stream>/index.m3u8?token=...` and `index.fmp4.m3u8` — live;
- `/<stream>/recording_status.json?token=...` — archive ranges;
- `/<stream>/index-<from>-<duration>.m3u8?token=...` — archive playback;
- `/<stream>/archive-<from>-<duration>.mp4?token=...` — direct download;
- canonical CORS and Private Network Access headers.

The locally controlled test page may replace its player and call these endpoints directly. No other SmartYard-Vue component has to be changed.

## Hard external boundary

The unmodified upstream SmartYard-Vue uses its configured SmartYard API for archive discovery and download when `camera.serverType` is present:

- `/mobile/cctv/ranges`;
- `/mobile/cctv/recPrepare`;
- `/mobile/cctv/recDownload`.

Those requests are sent to the SmartYard/RBT origin, not to the NewDomofon media origin. NewDomofon cannot alter, answer, redirect, or add CORS to those responses from another origin.

Therefore, with no changes to SmartYard-Vue and no changes to SmartYard/RBT:

- preview and live can work through NewDomofon direct media URLs;
- archive and download can work in the locally controlled test player by using NewDomofon direct endpoints;
- archive controls in an unmodified upstream SmartYard-Vue cannot be repaired solely from the NewDomofon servers if its `/mobile/cctv/*` calls fail.

This is a browser origin and application-contract boundary, not a missing NewDomofon route.
