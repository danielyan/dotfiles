#!/usr/bin/env bash
# Tests for `mini`. Run: bash ~/.local/lib/mini/tests.sh
#
# Stubs ssh/mosh on PATH so the remote-invocation paths can be checked without
# a reachable Mini. Covers argument quoting, dispatch, and error handling.

set -uo pipefail
MINI="$HOME/bin/mini"
stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT
pass=0; fail=0

check() { # check <name> <expected-substring> <actual>
    if [[ "$3" == *"$2"* ]]; then printf '  ✓ %s\n' "$1"; pass=$((pass+1))
    else printf '  ✗ %s\n      want substring: %s\n      got: %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
check_rc() {
    if [ "$3" -eq "$2" ]; then printf '  ✓ %s\n' "$1"; pass=$((pass+1))
    else printf '  ✗ %s (want rc=%s, got %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

# ssh stub: succeeds for the reachability probe, echoes args otherwise.
cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "true" ] && exit 0; done
echo "SSH_ARGS: $*"
STUB
cat > "$stub_dir/mosh" <<'STUB'
#!/usr/bin/env bash
echo "MOSH_ARGS: $*"
STUB
chmod +x "$stub_dir/ssh" "$stub_dir/mosh"
export PATH="$stub_dir:$PATH"

echo "dispatch"
out=$("$MINI" help 2>&1);            check "help lists subcommands" "mini preflight" "$out"
out=$("$MINI" bogus 2>&1); rc=$?;    check "unknown command names itself" "unknown command 'bogus'" "$out"
check_rc "unknown command exits 1" 1 "$rc"
check "unknown command suggests connect" "mini connect bogus" "$out"

echo "run"
out=$("$MINI" run echo hello 2>&1);  check "run uses a login shell" "bash -lc" "$out"
check "run passes the command" "echo hello" "$out"
out=$("$MINI" run echo 'two words' 2>&1)
check "run quotes arguments with spaces" "two\\ words" "$out"
out=$("$MINI" run 'rm -rf /; echo pwned' 2>&1)
check "run quotes shell metacharacters" "\;" "$out"
out=$("$MINI" run 2>&1); rc=$?;      check_rc "run with no args exits 1" 1 "$rc"
check "run with no args explains usage" "usage: mini run" "$out"

echo "connect"
out=$("$MINI" connect 2>&1);         check "connect prefers mosh" "MOSH_ARGS" "$out"
check "connect attaches-or-creates" "tmux new -A -s main" "$out"
out=$("$MINI" connect scratch 2>&1); check "connect honours a session name" "tmux new -A -s scratch" "$out"
out=$(MINI_HOST=elsewhere "$MINI" connect 2>&1)
check "MINI_HOST is respected" "elsewhere" "$out"

echo "unreachable"
cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
exit 255
STUB
chmod +x "$stub_dir/ssh"
out=$("$MINI" connect 2>&1); rc=$?
check "connect fails with a useful message" "cannot reach" "$out"
check_rc "connect exits 1 when unreachable" 1 "$rc"
out=$("$MINI" ls 2>&1); rc=$?;       check_rc "ls exits 1 when unreachable" 1 "$rc"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
