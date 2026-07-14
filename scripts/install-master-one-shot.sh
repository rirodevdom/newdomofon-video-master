#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO_URL="${REPO_URL:-https://github.com/rirodevdom/newdomofon-video-master.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-master}"
MASTER_DOMAIN="${MASTER_DOMAIN:-}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"
ADMIN_LOGIN="${ADMIN_LOGIN:-admin}"
TLS_MODE="${TLS_MODE:-auto}"

is_ipv4() {
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]
}

while (($#)); do
  case "$1" in
    --domain) MASTER_DOMAIN="${2:-}"; shift 2 ;;
    --email) CERTBOT_EMAIL="${2:-}"; shift 2 ;;
    --admin-login) ADMIN_LOGIN="${2:-}"; shift 2 ;;
    --project-dir) PROJECT_DIR="${2:-}"; shift 2 ;;
    --no-tls) TLS_MODE=no; shift ;;
    --tls) TLS_MODE=yes; shift ;;
    --regenerate-secrets) REGENERATE_SECRETS=true; export REGENERATE_SECRETS; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: install-master-one-shot.sh --domain DOMAIN [--email EMAIL]
       [--admin-login LOGIN] [--no-tls|--tls] [--regenerate-secrets]
EOF
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 77
fi

if [[ -z "$MASTER_DOMAIN" && -t 0 ]]; then
  read -r -p "Master domain or IP: " MASTER_DOMAIN
fi
MASTER_DOMAIN="${MASTER_DOMAIN#http://}"
MASTER_DOMAIN="${MASTER_DOMAIN#https://}"
MASTER_DOMAIN="${MASTER_DOMAIN%%/*}"
[[ -n "$MASTER_DOMAIN" ]] || { echo "Master domain or IP is required" >&2; exit 64; }

if [[ -z "$CERTBOT_EMAIL" && -t 0 && "$TLS_MODE" != no ]] && ! is_ipv4 "$MASTER_DOMAIN"; then
  read -r -p "Email for Let's Encrypt (optional): " CERTBOT_EMAIL
fi

export REPO_URL REPO_BRANCH PROJECT_DIR MASTER_DOMAIN CERTBOT_EMAIL ADMIN_LOGIN TLS_MODE

BOOTSTRAP_DIR="$(mktemp -d)"
trap 'rm -rf "$BOOTSTRAP_DIR"' EXIT

if [[ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/master-one-shot-install.sh" ]]; then
  SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
else
  apt-get update
  apt-get install -y ca-certificates curl git
  git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$BOOTSTRAP_DIR/repo"
  SCRIPT_ROOT="$BOOTSTRAP_DIR/repo"
fi

bash "$SCRIPT_ROOT/scripts/lib/master-one-shot-install.sh"
