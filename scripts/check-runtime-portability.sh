#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -d "$ROOT" ]] || fail "repository root not found: $ROOT"
command -v grep >/dev/null 2>&1 || fail "grep is required"

# Only paths that participate in installation, runtime URL generation, browser
# requests, reverse proxying, or the supported SmartYard integration are
# checked. Historical diagnostics and prose-only migration notes are excluded.
targets=(
  backend
  frontend/src
  deploy
  smartyard-compat-proxy
  integrations/smartyard-vue
  scripts/lib/master-one-shot-install.sh
  scripts/install-master-local-root.sh
  scripts/repair-public-https-origin.sh
  scripts/repair-public-media-cors.sh
  scripts/verify-smartyard-public-cors.sh
  scripts/fix-nginx-smartyard-events-route.sh
)

existing=()
for target in "${targets[@]}"; do
  [[ -e "$ROOT/$target" ]] && existing+=("$ROOT/$target")
done

((${#existing[@]})) || fail "no runtime portability targets found"

patterns=(
  'domofon-37\.ru'
  '10\.106\.[0-9]+\.[0-9]+'
  '3348ffdf-2455-472f-a941-4eb456fb1df6'
)

failed=0
for pattern in "${patterns[@]}"; do
  matches="$(grep -RnsI -E "$pattern" "${existing[@]}" 2>/dev/null || true)"
  if [[ -n "$matches" ]]; then
    echo "Deployment-specific value matched: $pattern" >&2
    echo "$matches" >&2
    failed=1
  fi
done

# Public browser URLs must be produced by environment variables, request
# headers, or supplied camera URLs. Fixed absolute HTTP(S) origins in runtime
# TypeScript/JavaScript are allowed only for reserved example domains.
absolute_origins="$(
  grep -RnsI -E \
    'https?://[A-Za-z0-9._-]+\.[A-Za-z]{2,}([/:"'"'`[:space:]]|$)' \
    "$ROOT/backend/src" "$ROOT/frontend/src" "$ROOT/smartyard-compat-proxy" \
    2>/dev/null |
  grep -vE 'https?://([^/]+\.)?(example\.(com|org|net)|example\.test|localhost)([/:"'"'`[:space:]]|$)' |
  grep -vE 'http://(www\.w3\.org|docs\.oasis-open\.org|www\.onvif\.org)/' |
  grep -vE 'https://developer\.mozilla\.org/' || true
)"

if [[ -n "$absolute_origins" ]]; then
  echo "Fixed absolute public origins found in runtime code:" >&2
  echo "$absolute_origins" >&2
  failed=1
fi

if ((failed)); then
  exit 1
fi

echo "Runtime portability check passed."
echo "Public hosts are supplied by environment, request headers, or camera URLs."
