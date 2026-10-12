#!/usr/bin/env bash
# Tests for ~/bin/machine-where (which Mac, and how you are on it), the
# Claude status line's machine label built on it
# (~/.config/ccstatusline/machine), and the two widgets that call it.
# Run: bash ~/.local/lib/yadm/ccstatusline-machine-tests.sh

set -uo pipefail
M="$HOME/.config/ccstatusline/machine"
W="$HOME/bin/machine-where"
SETTINGS="$HOME/.config/ccstatusline/settings.json"
pass=0; fail=0
check() { if [[ "$3" == *"$2"* ]]; then printf '  ✓ %s\n' "$1"; pass=$((pass+1))
          else printf '  ✗ %s\n      want: %q\n      got:  %q\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
empty() { if [ -z "$2" ]; then printf '  ✓ %s\n' "$1"; pass=$((pass+1))
          else printf '  ✗ %s (printed %q)\n' "$1" "$2"; fail=$((fail+1)); fi; }

# where <host> <ancestors> [VAR=value...]: machine-where with no tmux or ssh
# variables but the ones given, and a fixed ancestor walk.
where() { local host=$1 anc=$2; shift 2
          env -u TMUX -u SSH_CONNECTION -u SSH_TTY MACHINE_HOSTNAME="$host" \
              MACHINE_ANCESTORS="$anc" "$@" "$W" </dev/null; }
local_tree=$'fish\nlogin\nGhostty'

# run <host> <widget> [ancestors]: the label, outside tmux, local by default.
run() { env -u TMUX -u SSH_CONNECTION -u SSH_TTY MACHINE_HOSTNAME="$1" \
            MACHINE_ANCESTORS="${3-$local_tree}" "$M" "$2" </dev/null; }
orange=$'\033[1;38;5;208m'
teal=$'\033[1;38;5;37m'

echo "machine-where"
check "a plain terminal on the Mini is local"   "mini local"    "$(where mini "$local_tree")"
check "a tmux pane is a session"                "mini session"  "$(where mini "$local_tree" TMUX=/tmp/tmux-501/default,1,0)"
check "so is an ssh login"                      "mini session"  "$(where mini "$local_tree" SSH_CONNECTION='1.2.3.4 5 6.7.8.9 22')"
check "an SSH_TTY alone is enough"              "mini session"  "$(where mini "$local_tree" SSH_TTY=/dev/ttys001)"
check "mosh, which sets no SSH_*, by ancestry"  "mini session"  "$(where mini $'fish\nmosh-server')"
check "sshd by its full path too"               "mini session"  "$(where mini $'fish\n/usr/sbin/sshd')"
check "and macOS's sshd-session"                "mini session"  "$(where mini $'fish\nsshd-session\nsshd')"
check "a name merely ending in sshd is not"     "mini local"    "$(where mini $'fish\nnotsshd')"
check "the laptop is called air"                "air local"     "$(where Levs-MacBook-Air "$local_tree")"
check "host names are lowered"                  "studio local"  "$(where Studio "$local_tree")"
check "the real walk runs without overrides"    "session"       "$(TMUX=x "$W")"

echo "each machine shows exactly one label"
check "the Mini's server widget names it"        "mini"            "$(run mini server)"
check "teal at the Mini's own keyboard"          "$teal"           "$(run mini server)"
check "orange in a session, like the tide badge" "$orange"         "$(run mini server $'fish\nmosh-server')"
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
