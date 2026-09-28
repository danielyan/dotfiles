#!/usr/bin/env bash
# Tests for ~/.config/ccstatusline/machine, the Claude status line's machine
# label, and the two widgets that call it.
# Run: bash ~/.local/lib/yadm/ccstatusline-machine-tests.sh

set -uo pipefail
M="$HOME/.config/ccstatusline/machine"
SETTINGS="$HOME/.config/ccstatusline/settings.json"
pass=0; fail=0
check() { if [[ "$3" == *"$2"* ]]; then printf '  ✓ %s\n' "$1"; pass=$((pass+1))
          else printf '  ✗ %s\n      want: %q\n      got:  %q\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
empty() { if [ -z "$2" ]; then printf '  ✓ %s\n' "$1"; pass=$((pass+1))
          else printf '  ✗ %s (printed %q)\n' "$1" "$2"; fail=$((fail+1)); fi; }

run() { MACHINE_HOSTNAME="$1" "$M" "$2" </dev/null; }
orange=$'\033[1;38;5;208m'

echo "each machine shows exactly one label"
check "the Mini's server widget names it"        "mini"            "$(run mini server)"
check "in orange, like the tide badge"           "$orange"         "$(run mini server)"
check "and puts the colour back after"           $'\033[22;39m'    "$(run mini server)"
empty "the Mini's other widget is empty"                            "$(run mini other)"
check "the Air's other widget says air"          "air"             "$(run Levs-MacBook-Air other)"
empty "the Air's server widget is empty"                            "$(run Levs-MacBook-Air server)"
check "any other Mac is named by its host name"  "studio"          "$(run Studio other)"
empty "and is never the server"                                     "$(run Studio server)"
check "host names are compared in any case"      "mini"            "$(run MINI server)"
empty "an unknown argument prints nothing"                          "$(run mini sideways)"

echo "the widgets"
widgets=$(python3 - "$SETTINGS" <<'PY'
import json, sys
line = json.load(open(sys.argv[1]))["lines"][0]
for i, w in enumerate(line):
    if w.get("type") == "custom-command" and "ccstatusline/machine" in w.get("commandPath", ""):
        print(i, w["commandPath"].split()[-1], "preserve" if w.get("preserveColors") else "plain")
PY
)
check "the server widget comes first" "0 server preserve" "$widgets"
check "the other widget second"       "1 other plain"     "$widgets"
check "exactly two"                   "2" "$(printf '%s\n' "$widgets" | grep -c .)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
