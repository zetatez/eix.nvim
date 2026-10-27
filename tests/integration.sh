#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eix_bin="${EIX_BIN:-eix}"

if ! command -v "$eix_bin" >/dev/null 2>&1; then
	echo "eix binary not found: $eix_bin (set EIX_BIN)" >&2
	exit 1
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/eix-nvim-test.XXXXXX")"
socket="$tmp/eix.sock"
data="$tmp/data"
config="$tmp/config.yaml"
work="$tmp/work"
pid=""

cleanup() {
	if [ -n "$pid" ]; then
		kill "$pid" 2>/dev/null || true
	fi
	rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "$data" "$work"
printf '{}\n' >"$config"

export EIX_SOCKET="$socket"
export EIX_DATA_DIR="$data"
export EIX_CONFIG="$config"

status_json="$("$eix_bin" status --json)"
pid="$(printf '%s' "$status_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["daemon"]["pid"])')"

EIX_TEST_SOCKET="$socket" EIX_TEST_WORK="$work" \
	nvim --headless -u "$root/tests/minimal_init.lua" -l "$root/tests/integration.lua"
