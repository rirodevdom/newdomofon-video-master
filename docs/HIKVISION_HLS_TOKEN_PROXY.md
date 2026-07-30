# Hikvision HLS token boundary

The browser receives a short-lived media token signed with the Hikvision node `media_secret`. The master validates this token on every `/api/hikvision-media/...` request.

Server-to-server requests from master to Hikvision-node use a separate token derived from the node agent credential. Hikvision-node may embed that upstream token in the HLS playlist it returns. Before the playlist is sent to the browser, master rewrites all media URI tokens back to the browser token.

This applies to:

- ordinary HLS URI lines (`*.ts`, nested playlists, init segments);
- `URI="..."` attributes such as `EXT-X-MAP`, `EXT-X-KEY`, and `EXT-X-MEDIA`;
- live and archive playlists.

The upstream credential must never be exposed to the browser. Binary segments are streamed unchanged after the browser token is validated by master.
