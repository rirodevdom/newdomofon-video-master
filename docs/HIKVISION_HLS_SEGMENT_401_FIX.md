# Hikvision HLS segment 401 fix

Symptom: live/archive playlists returned HTTP 200, while the following TS segment requests returned HTTP 401.

Cause: Hikvision-node embedded the server-to-server upstream media token in playlist segment URIs. The master media gateway validates browser requests with the node media secret, so it correctly rejected the different upstream token.

Fix: master buffers only `.m3u8` responses, replaces URI tokens with the already validated browser token, adjusts content length, and then returns the playlist. Binary media responses continue to stream without buffering.
