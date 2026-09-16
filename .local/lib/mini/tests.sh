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

echo "pair: folder json"
# add-json does NOT merge with defaults — every field omitted becomes a Go zero
# value. These two silently break sync if left out, so assert them explicitly.
MINI_HOST=mini MINI_SESSION=main HOME="$HOME" bash -c '
  MINI_FOLDER_PATH=$HOME/.claude
  . "$HOME/.local/lib/mini/pair.sh"
  _folder_json PEERID MYID
' > "$stub_dir/folder.json" 2>/dev/null

json=$(cat "$stub_dir/folder.json")
if python3 -c "import json,sys; json.load(open('$stub_dir/folder.json'))" 2>/dev/null; then
    printf '  ✓ folder json is valid json\n'; pass=$((pass+1))
else
    printf '  ✗ folder json is not valid json\n'; fail=$((fail+1))
fi
val() { python3 -c "import json;d=json.load(open('$stub_dir/folder.json'));print(d$1)" 2>/dev/null; }
check "maxConflicts is 10, not the zero value that discards writes" "10" "$(val "['maxConflicts']")"
check "fsWatcherEnabled is true, not the zero value" "True" "$(val "['fsWatcherEnabled']")"
check "versioning is staggered" "staggered" "$(val "['versioning']['type']")"
check "maxAge is 30 days in seconds" "2592000" "$(val "['versioning']['params']['maxAge']")"
check "ignoreDelete stays off" "False" "$(val "['ignoreDelete']")"
check "folder is bidirectional" "sendreceive" "$(val "['type']")"
check "both devices are shared" "2" "$(python3 -c "import json;d=json.load(open('$stub_dir/folder.json'));print(len(d['devices']))" 2>/dev/null)"
check "peer device is included" "PEERID" "$json"

echo "land: survey and confirmation"
# A fixture with one repo ahead, one dirty, one with no remote.
land_fix=$(mktemp -d)
git init -q --bare "$land_fix/up.git"
git init -q "$land_fix/seed" >/dev/null
( cd "$land_fix/seed" && git config user.email t@t && git config user.name t \
  && echo a > f && git add . && git commit -qm init && git branch -M main \
  && git remote add origin ../up.git && git push -q origin main ) >/dev/null 2>&1
git clone -q "$land_fix/up.git" "$land_fix/p/ahead" 2>/dev/null
mkdir -p "$land_fix/p"
git clone -q "$land_fix/up.git" "$land_fix/p/ahead" 2>/dev/null
( cd "$land_fix/p/ahead" && git config user.email t@t && git config user.name t \
  && echo b >> f && git commit -qam "offline work" ) >/dev/null 2>&1
git clone -q "$land_fix/up.git" "$land_fix/p/dirtyrepo" 2>/dev/null
echo scratch > "$land_fix/p/dirtyrepo/uncommitted"
git init -q "$land_fix/p/noremote" >/dev/null

# ssh stub: reachability probe succeeds, remote catch-up returns nothing.
cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "true" ] && exit 0; done
exit 0
STUB
chmod +x "$stub_dir/ssh"

out=$(printf 'n\n' | PROJECTS_DIR="$land_fix/p" "$MINI" land 2>&1)
check "land finds the repo that is ahead" "ahead (1 commit(s))" "$out"
check "land reports the dirty repo" "dirtyrepo — uncommitted changes" "$out"
refute() { if [[ "$3" != *"$2"* ]]; then printf '  ✓ %s\n' "$1"; pass=$((pass+1));
           else printf '  ✗ %s (found: %s)\n' "$1" "$2"; fail=$((fail+1)); fi; }
refute "land ignores the repo with no remote" "noremote (" "$out"
check "declining skips the push" "skipped pushing" "$out"

# Declining must genuinely not push.
remote_head=$(git -C "$land_fix/up.git" rev-parse main 2>/dev/null)
local_head=$(git -C "$land_fix/p/ahead" rev-parse HEAD 2>/dev/null)
if [ "$remote_head" != "$local_head" ]; then
    printf '  ✓ declining really left the remote untouched\n'; pass=$((pass+1))
else
    printf '  ✗ declining still pushed\n'; fail=$((fail+1))
fi
# Accepting must actually push.
out=$(printf 'y\n' | PROJECTS_DIR="$land_fix/p" "$MINI" land 2>&1)
check "accepting reports the push" "ahead pushed" "$out"
remote_head=$(git -C "$land_fix/up.git" rev-parse main 2>/dev/null)
local_head=$(git -C "$land_fix/p/ahead" rev-parse HEAD 2>/dev/null)
if [ "$remote_head" = "$local_head" ]; then
    printf '  ✓ the commit really reached the remote\n'; pass=$((pass+1))
else
    printf '  ✗ accepting did not push\n'; fail=$((fail+1))
fi
check "dirty repo still not pushed" "dirtyrepo — uncommitted changes" "$out"
rm -rf "$land_fix"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
