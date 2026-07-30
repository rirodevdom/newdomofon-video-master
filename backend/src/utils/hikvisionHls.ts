function withBrowserToken(uri: string, browserToken: string): string {
  if (!uri || /^(?:data|blob):/i.test(uri)) return uri;

  const hashIndex = uri.indexOf('#');
  const beforeHash = hashIndex >= 0 ? uri.slice(0, hashIndex) : uri;
  const fragment = hashIndex >= 0 ? uri.slice(hashIndex) : '';
  const encodedToken = encodeURIComponent(browserToken);

  const tokenPattern = /([?&])token=[^&#]*/i;
  if (tokenPattern.test(beforeHash)) {
    return beforeHash.replace(tokenPattern, `$1token=${encodedToken}`) + fragment;
  }

  const separator = beforeHash.includes('?') ? '&' : '?';
  return `${beforeHash}${separator}token=${encodedToken}${fragment}`;
}

/**
 * Replaces the node-only upstream credential embedded in an HLS playlist with
 * the browser token validated by the master media gateway. This applies to
 * plain URI lines and URI="..." attributes used by EXT-X-MAP/KEY/MEDIA tags.
 */
export function rewriteHlsPlaylistBrowserToken(playlist: string, browserToken: string): string {
  const newline = playlist.includes('\r\n') ? '\r\n' : '\n';

  return playlist.split(/\r?\n/).map((line) => {
    const core = line.trim();
    if (!core) return line;

    if (core.startsWith('#')) {
      return line.replace(/URI="([^"]+)"/g, (_match, uri: string) => `URI="${withBrowserToken(uri, browserToken)}"`);
    }

    const leading = line.match(/^\s*/)?.[0] || '';
    const trailing = line.match(/\s*$/)?.[0] || '';
    return `${leading}${withBrowserToken(core, browserToken)}${trailing}`;
  }).join(newline);
}
