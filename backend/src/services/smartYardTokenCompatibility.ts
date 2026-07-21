const RECORDING_TOKEN_PREFIX = '100';

/**
 * Original SmartYard-Server prepends the historical `100` marker while
 * preparing an archive MP4. Live playback sends the same camera token without
 * that marker. Always validate the token exactly as received first and expose
 * the stripped form only as a compatibility fallback.
 */
export function smartYardTokenCandidates(rawToken: string): string[] {
  const token = String(rawToken || '').trim();
  if (!token) return [];

  const candidates = [token];
  if (token.startsWith(RECORDING_TOKEN_PREFIX) && token.length > RECORDING_TOKEN_PREFIX.length) {
    const withoutPrefix = token.slice(RECORDING_TOKEN_PREFIX.length);
    if (withoutPrefix && !candidates.includes(withoutPrefix)) candidates.push(withoutPrefix);
  }

  return candidates;
}
