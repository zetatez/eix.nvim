#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

nvim --headless -u "$root/tests/minimal_init.lua" -l "$root/tests/unit.lua"
"$root/tests/integration.sh"
