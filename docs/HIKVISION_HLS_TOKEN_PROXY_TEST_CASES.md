# Regression cases

The Hikvision HLS proxy regression test verifies:

1. live segment URIs replace an existing node token;
2. segment URIs without a token receive the browser token;
3. archive `EXT-X-MAP` and `EXT-X-KEY` URI attributes are rewritten;
4. unrelated query parameters and URL fragments are preserved;
5. CRLF playlists retain their newline convention;
6. data URIs remain unchanged.
