#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -d "$ROOT" ]] || fail "repository root not found: $ROOT"
command -v grep >/dev/null 2>&1 || fail "grep is required"

# Paths that participate in installation, runtime URL generation, browser
# requests, reverse proxying, or the supported SmartYard integration.
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

# These values belong to one historical production installation and must never
# be used as defaults, fallbacks, placeholders, or request targets in runtime
# and installation paths. Reserved example domains and RFC 5737 addresses are
# intentionally allowed for documentation and UI placeholders.
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

if ((failed)); then
  exit 1
fi

echo "Runtime portability check passed."
echo "Current production domain, subnet, and node ID are absent from runtime paths."
