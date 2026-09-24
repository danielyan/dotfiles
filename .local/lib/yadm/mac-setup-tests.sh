#!/usr/bin/env bash
# Tests for bin/mac-setup.
# Run: bash ~/.local/lib/yadm/mac-setup-tests.sh
#
# mac-setup is documented as `curl ... | bash -s -- --server`. Piped like
# that, bash reads the script from stdin, and everything it launches inherits
# the pipe instead of the terminal: the Homebrew installer drops to
# non-interactive mode and cannot ask for a sudo password, and every `read`
# prompt in bootstrap silently gets EOF, i.e. "no". These tests pipe the real
# script into bash under a pseudo-terminal (`script`) and check that yadm
# bootstrap receives the terminal.
#
# brew and yadm are stubbed as exported functions rather than PATH entries:
# mac-setup prepends /opt/homebrew/bin, which would find the real tools
# first, but functions take precedence over PATH.

set -uo pipefail
SUT="$HOME/bin/mac-setup"
pass=0; fail=0

check() {
    if [[ "$3" == *"$2"* ]]; then printf '  ✓ %s\n' "$1"; pass=$((pass+1))
    else printf '  ✗ %s\n      want: %s\n      got:  %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

# $1 = "tty" to run under a pseudo-terminal, anything else for none
run_case() {
    local tmp; tmp=$(mktemp -d)
    local runner="$tmp/run.sh"
    cat > "$runner" <<RUNNER
export HOME='$tmp' LOG='$tmp/log'
brew() { echo "brew \$*" >> "\$LOG"; }
yadm() {
    local t=no; [ -t 0 ] && t=yes
    echo "yadm \$* stdin_tty=\$t" >> "\$LOG"
    # Stand-in for bootstrap's ask(): must reach the user, not the pipe.
    if [ "\$1" = bootstrap ]; then
        read -r -t 2 answer || answer='<eof>'
        echo "prompt got: \$answer" >> "\$LOG"
    fi
}
export -f brew yadm
cat '$SUT' | bash -s -- --server
echo "exit=\$?" >> "\$LOG"
RUNNER
    if [ "$1" = tty ]; then
        # Feed a keystroke through the pty, as a person answering "y" would.
        (sleep 1; echo y) | script -q /dev/null bash "$runner" >/dev/null 2>&1
    else
        bash "$runner" </dev/null >/dev/null 2>&1
    fi
    cat "$tmp/log" 2>/dev/null
    rm -rf "$tmp"
}

echo "piped into bash from a terminal (the documented one-liner)"
out=$(run_case tty)
check "clones the dotfiles"              "yadm clone https://github.com/danielyan/dotfiles.git" "$out"
check "passes --server to bootstrap"     "yadm bootstrap --server"  "$out"
check "bootstrap gets the terminal"      "bootstrap --server stdin_tty=yes" "$out"
check "bootstrap's prompts reach the user" "prompt got: y"          "$out"
check "exits cleanly"                    "exit=0"                   "$out"

echo "no terminal at all (CI, cron)"
out=$(run_case none)
check "still runs bootstrap"             "yadm bootstrap --server stdin_tty=no" "$out"
check "prompts see EOF, not a hang"      "prompt got: <eof>"        "$out"
check "exits cleanly"                    "exit=0"                   "$out"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
