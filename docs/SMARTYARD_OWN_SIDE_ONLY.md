# SmartYard integration: NewDomofon-controlled media and opt-in frontend source patch

The core NewDomofon deployment must not require changes on RBT or SmartYard-Server. Media compatibility remains implemented by NewDomofon master/node.

A deployment owner may explicitly apply the repository's source-only patch to a SmartYard-Vue checkout that they control, build it normally, and publish that build. This is different from modifying a third-party server or injecting code into already published assets.

## What NewDomofon can guarantee

NewDomofon master/node provide direct media endpoints for a camera URL returned to a browser:

- `/<stream>/preview.mp4?token=...` — still, silent preview;
- `/<stream>/<unix>-preview.mp4?token=...` — timestamp preview;
- `/<stream>/index.m3u8?token=...` and `index.fmp4.m3u8` — live;
- `/<stream>/recording_status.json?token=...` — archive ranges;
- `/<stream>/index-<from>-<duration>.m3u8?token=...` — archive playback;
- `/<stream>/archive-<from>-<duration>.mp4?token=...` — direct download;
- canonical CORS and Private Network Access headers.

The locally controlled test page may replace its player and call these endpoints directly.

## SmartYard API boundary

SmartYard-Vue uses its configured SmartYard API for prepared downloads:

- `/mobile/cctv/recPrepare`;
- `/mobile/cctv/recDownload`.

Those requests are sent to the SmartYard/RBT origin, not to the NewDomofon media origin. NewDomofon cannot alter, answer, redirect, or add CORS to responses from another origin.

SmartYard-Server may return a preparation id first and keep returning `204 No Content` until the MP4 is ready. An unmodified frontend that checks `recDownload` once cannot show a URL that appears later.

## Allowed source-level compatibility patch

The deployment owner may run:

```bash
python3 scripts/patch-smartyard-download-ready-link.py \
  --project-dir /path/to/SmartYard-Vue
```

The patch:

- changes only the owner's SmartYard-Vue source checkout;
- supports original `CustomControls.vue` and integrated `smartyardPlayerKit.ts`;
- polls `recDownload` until a URL is returned;
- displays a persistent download link;
- creates a source backup;
- contains no deployment-specific hostname or IP address.

Afterward the owner runs the normal frontend build and publishes its `dist` directory.

## Forbidden actions

NewDomofon tooling must not:

- modify SmartYard-Server or RBT;
- inject code into a live third-party frontend at runtime;
- rewrite already published third-party assets silently;
- include a production domain or installation IP as a fallback;
- apply source changes without an explicit owner command.

This preserves the browser-origin and application-contract boundary while allowing the owner to repair a frontend behavior in a copy they are authorized to build and deploy.
