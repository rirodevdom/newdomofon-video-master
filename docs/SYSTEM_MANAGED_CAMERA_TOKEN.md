# System-managed camera token

## Assignment model

Managed camera tokens remain many-to-many:

- one camera may have multiple user-managed tokens;
- one user-managed token may be assigned to multiple cameras;
- adding another user-managed token never removes existing user assignments.

The protected system token is only a fallback:

- a newly created camera receives it automatically;
- assigning the first user-managed token removes only the system fallback;
- removing one of several user-managed tokens keeps the other assignments;
- removing the last user-managed token restores the system fallback;
- the protected system token cannot be disabled, rotated or manually removed.

The fixed system token row is:

```text
00000000-0000-4000-8000-000000000001
```

## Admin playback

The admin player uses an active managed token assigned to the camera. When several user-managed tokens are assigned, the most recently assigned active token with the `camera` scope is selected. The system token is selected only when no active user-managed token is available.

The browser-facing URL carries an `m1...` token. The master SmartYard media gateway validates it and then creates a short-lived internal HMAC token for the assigned video node. The video node never receives or validates the reusable managed token directly.

Public admin URLs may use the camera-prefixed form:

```text
/cameras/<stream_name>/live.m3u8?token=m1...
/cameras/<stream_name>/archive.m3u8?start=...&end=...&token=m1...
```

Gateway parsers must remove the leading `cameras/` component before resolving `stream_name`. Without this normalization the resolver sees `cameras` as the stream, falls back to the legacy handler and returns 401/403 for a valid managed token.

The deployment patch `scripts/patch-managed-media-gateway.py` normalizes this path in the node-aware, event, preview and format gateway layers. It also prevents managed-token resolver errors from being silently hidden by the legacy fallback.

## Runtime secrets

`MANAGED_CAMERA_TOKEN_SECRET` signs reusable managed tokens. Existing installations initialize it from the current `JWT_SECRET` so already issued tokens remain valid.

`INTERNAL_DVR_SECRET` authenticates calls from the SmartYard media gateway to the backend resolver. The rollout and the normal master deployment generate it automatically when it is absent. Both the backend and gateway read the same `/etc/newdomofon-video/app.env` file.

## Rollout

Test the branch on master:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/rirodevdom/newdomofon-video-master/agent/system-managed-camera-token/scripts/apply-managed-token-rollout.sh \
  -o /root/apply-managed-token-rollout.sh
chmod 700 /root/apply-managed-token-rollout.sh
TARGET_REF=agent/system-managed-camera-token \
  bash /root/apply-managed-token-rollout.sh master
```

The rollout:

- creates a PostgreSQL and environment backup;
- preserves managed-token signing compatibility;
- ensures the internal gateway secret exists;
- applies database, UI and gateway patches;
- installs and restarts `newdomofon-smartyard-compat.service`;
- verifies the backend on port 3000;
- verifies the public gateway on port 3082;
- verifies the node-aware inner gateway on port 3084;
- checks that port 3084 reports `v301-node-aware-smartyard-gateway` and `internal_secret_configured=true`;
- checks the system-token fallback invariants in PostgreSQL.
