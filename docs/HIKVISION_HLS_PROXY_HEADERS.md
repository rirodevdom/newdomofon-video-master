# Diagnostic headers

Rewritten HLS playlist responses include:

- `x-newdomofon-hikvision-media-proxy: master`
- `x-newdomofon-hikvision-upstream-auth: agent-token-hash`
- `x-newdomofon-hikvision-playlist-token: browser`

The last header confirms that embedded HLS URIs were rewritten to use the browser token before delivery.
