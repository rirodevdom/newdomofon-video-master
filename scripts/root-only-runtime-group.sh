#!/usr/bin/env bash
# Helper sourced by master deployment scripts that need a readable runtime group.
# Root-only installations do not require an OS account named newdomofon.

runtime_group() {
  if getent group newdomofon >/dev/null 2>&1; then
    printf '%s\n' newdomofon
  else
    printf '%s\n' root
  fi
}
