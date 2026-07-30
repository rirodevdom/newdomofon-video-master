import assert from 'node:assert/strict';
import { rewriteHlsPlaylistBrowserToken } from '../src/utils/hikvisionHls.js';

const browserToken = 'browser.token_123';

const live = rewriteHlsPlaylistBrowserToken(`#EXTM3U\n#EXT-X-VERSION:3\nseg_000001.ts?token=upstream-token&part=1\nseg_000002.ts\n`, browserToken);
assert.match(live, /seg_000001\.ts\?token=browser\.token_123&part=1/);
assert.match(live, /seg_000002\.ts\?token=browser\.token_123/);
assert.doesNotMatch(live, /upstream-token/);

const archive = rewriteHlsPlaylistBrowserToken(`#EXTM3U\r\n#EXT-X-MAP:URI="init.mp4?token=node-secret&v=7"\r\n#EXT-X-KEY:METHOD=AES-128,URI="keys/key.bin"\r\nsegment.ts?x=1&token=node-secret#frag\r\n`, browserToken);
assert.match(archive, /URI="init\.mp4\?token=browser\.token_123&v=7"/);
assert.match(archive, /URI="keys\/key\.bin\?token=browser\.token_123"/);
assert.match(archive, /segment\.ts\?x=1&token=browser\.token_123#frag/);
assert.ok(archive.includes('\r\n'));

const absolute = rewriteHlsPlaylistBrowserToken('https://node.local/live/seg.ts?token=private\n', browserToken);
assert.equal(absolute, 'https://node.local/live/seg.ts?token=browser.token_123\n');

const dataUri = rewriteHlsPlaylistBrowserToken('#EXT-X-KEY:METHOD=NONE,URI="data:text/plain,abc"\n', browserToken);
assert.equal(dataUri, '#EXT-X-KEY:METHOD=NONE,URI="data:text/plain,abc"\n');

console.log('Hikvision HLS browser-token rewrite tests passed');
