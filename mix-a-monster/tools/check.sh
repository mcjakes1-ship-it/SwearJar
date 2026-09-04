#!/usr/bin/env bash
# Type-check the whole project against the real Roblox API.
#   tools/check.sh            -> analyze everything
#   tools/check.sh path.luau  -> analyze one file
#
# Requires LUAU_TOOLS to point at a directory holding `luau-lsp`, `luau-compile`
# and `globalTypes.d.luau` (see docs/README.md → Toolchain).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="${LUAU_TOOLS:-$ROOT/.tools}"
cd "$ROOT"


# A private sourcemap per invocation: several agents/terminals may run this
# concurrently and must not race on one shared file.
MAP="$(mktemp -t mixmap.XXXXXX.json)"
trap 'rm -f "$MAP"' EXIT
python3 tools/sourcemap.py "$MAP" 2>/dev/null

FILES=()
if [ "$#" -gt 0 ]; then FILES=("$@"); else
  while IFS= read -r f; do FILES+=("$f"); done < <(find src -name '*.luau' | sort)
fi

fail=0
for f in "${FILES[@]}"; do
  if ! "$TOOLS/luau-compile" --binary "$f" >/dev/null 2>&1; then
    echo "SYNTAX FAIL: $f"
    "$TOOLS/luau-compile" --binary "$f" 2>&1 | head -5
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "syntax: ${#FILES[@]} file(s) OK"

"$TOOLS/luau-lsp" analyze \
  --sourcemap="$MAP" \
  --definitions="$TOOLS/globalTypes.d.luau" \
  --settings=tools/luau-lsp.settings.json \
  --base-luaurc=tools/.luaurc \
  --no-strict-dm-types \
  "${FILES[@]}"
rc=$?
[ "$rc" -ne 0 ] && fail=1
exit "$fail"
