#!/usr/bin/env bash
# Behavioural tests for the realm-agnostic modules. See tools/spec/spec.luau.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLS="${LUAU_TOOLS:-$ROOT/.tools}"
cd "$ROOT"
python3 tools/spec/bundle.py tools/spec/bundle.luau
"$TOOLS/luau" tools/spec/spec.luau
