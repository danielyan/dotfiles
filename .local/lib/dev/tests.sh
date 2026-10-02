#!/usr/bin/env bash
# Tests for `dev`. Run: bash ~/.local/lib/dev/tests.sh
#
# Stubs ssh/mosh on PATH so the remote-invocation paths can be checked without
# a reachable Mini. Covers argument quoting, dispatch, and error handling.

set -uo pipefail
DEV="$HOME/bin/dev"
stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT
pass=0; fail=0

check() { # check <name> <expected-substring> <actual>
    if [[ "$3" == *"$2"* ]]; then printf '  ✓ %s\n' "$1"; pass=$((pass+1))
    else printf '  ✗ %s\n      want substring: %s\n      got: %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
refute() { if [[ "$3" != *"$2"* ]]; then printf '  ✓ %s\n' "$1"; pass=$((pass+1));
           else printf '  ✗ %s (found: %s)\n' "$1" "$2"; fail=$((fail+1)); fi; }
check_rc() {
    if [ "$3" -eq "$2" ]; then printf '  ✓ %s\n' "$1"; pass=$((pass+1))
    else printf '  ✗ %s (want rc=%s, got %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

# ssh stub: succeeds for the reachability probe, echoes args otherwise, and
# for remote_bash (`bash -ls`) the command line it was fed on stdin.
cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "true" ] && exit 0; done
echo "SSH_ARGS: $*"
[ "${*: -1}" = "bash -ls" ] && printf 'SSH_STDIN: %s\n' "$(cat)"
exit 0
STUB
cat > "$stub_dir/mosh" <<'STUB'
#!/usr/bin/env bash
echo "MOSH_ARGS: $*"
STUB
chmod +x "$stub_dir/ssh" "$stub_dir/mosh"
# Not the server, wherever the suite runs: on the Mini, connect would exec tmux.
printf '#!/usr/bin/env bash\nprintf " displaysleep         10\\n sleep                1\\n"\n' > "$stub_dir/pmset"
chmod +x "$stub_dir/pmset"
export PATH="$stub_dir:$PATH"
# A projects folder of the suite's own, and a working directory outside it, so
# which session `dev` picks does not depend on where the suite was started.
export DEV_PROJECTS_DIR="$stub_dir/projects"
mkdir -p "$DEV_PROJECTS_DIR"
cd "$stub_dir" || exit 1

echo "dispatch"
out=$("$DEV" help 2>&1);            check "help lists subcommands" "dev preflight" "$out"
out=$("$DEV" bogus 2>&1); rc=$?;    check "a non-command is a session" "no session 'bogus' on mini" "$out"
check_rc "and a missing one exits 1" 1 "$rc"
out=$("$DEV" -x 2>&1); rc=$?;       check "an unknown option is refused" "unknown option '-x'" "$out"
check_rc "and exits 1" 1 "$rc"

echo "run"
# What goes over the wire. Whether it arrives intact on a real login shell is
# checked by "remote commands arrive intact" below.
out=$("$DEV" run echo hello 2>&1);  check "run uses a login shell" "bash -ls" "$out"
check "run sends the command on stdin" "SSH_STDIN: echo hello" "$out"
out=$("$DEV" run echo 'two words' 2>&1)
check "run quotes arguments with spaces" "two\\ words" "$out"
out=$("$DEV" run 'rm -rf /; echo pwned' 2>&1)
check "run quotes shell metacharacters" "\;" "$out"
out=$("$DEV" run 2>&1); rc=$?;      check_rc "run with no args exits 1" 1 "$rc"
check "run with no args explains usage" "usage: dev run" "$out"

echo "connect: the stubbed Mini"
# Sessions "running" on the stubbed Mini are lines of $cs/running, as
# name|attached-clients: has-session and `tmux ls` both answer from it.
cs=$(mktemp -d)
cat > "$cs/ssh" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = true ] && exit 0; done
case "\$*" in *"has-session -t ="*)
    all="\$*"; name=\${all##*has-session -t =}; name=\${name%% *}
    cut -d'|' -f1 "$cs/running" | grep -qx -- "\$name"; exit \$? ;;
esac
if [ "\${*: -1}" = "bash -ls" ]; then
    case "\$(cat)" in *"tmux ls"*) cat "$cs/running" ;; esac
    exit 0
fi
echo "SSH_ARGS: \$*"
STUB
printf '#!/usr/bin/env bash\necho "MOSH_ARGS: $*"\n' > "$cs/mosh"
chmod +x "$cs/ssh" "$cs/mosh"
running() { : > "$cs/running"; local s; for s; do printf '%s\n' "$s" >> "$cs/running"; done; }
C() { PATH="$cs:$PATH" "$DEV" "$@" 2>&1; }
keys() { printf "$1" > "$cs/keys"; }      # what the "terminal" types next
mkdir -p "$DEV_PROJECTS_DIR/fresco/Sources" "$DEV_PROJECTS_DIR/my.proj" "$cs/scratch" "$cs/home"
check "connect prefers mosh" "MOSH_ARGS" "$(running main; C)"
check "DEV_HOST is respected" "elsewhere" "$(running main; PATH="$cs:$PATH" DEV_HOST=elsewhere "$DEV" 2>&1)"

echo "connect: dev"
running main fresco
out=$(cd "$DEV_PROJECTS_DIR/fresco/Sources" && C)
check  "in a project, its running session" "tmux new -A -s fresco" "$out"
refute "attaching, so no start folder"      " -c " "$out"
running main
out=$(cd "$DEV_PROJECTS_DIR/fresco" && C)
check  "a project with no session gets main" "tmux new -A -s main" "$out"
refute "and its session is not started"      "-s fresco" "$out"
running main scratch
check  "outside projects, the folder's own name" "tmux new -A -s scratch" "$(cd "$cs/scratch" && C)"
running main projects
check  "the projects folder itself is main" "tmux new -A -s main" "$(cd "$DEV_PROJECTS_DIR" && C)"
running main home
check  "and so is home" "tmux new -A -s main" "$(cd "$cs/home" && DEV_LIB="$HOME/.local/lib/dev" HOME="$cs/home" C)"
running
check  "with nothing running, main is started" "tmux new -A -s main" "$(cd "$cs/scratch" && C)"

echo "connect: dev <name>"
running main magpie two_words
check  "a running session is attached" "tmux new -A -s magpie" "$(C magpie)"
check  "names are cleaned the same way" "tmux new -A -s two_words" "$(C "two words")"
out=$(C fresco); rc=$?
check  "a missing one is reported"          "no session 'fresco' on mini" "$out"
check  "with how to start it"               "run dev fresco in a terminal to start it" "$out"
check_rc "and exits 1"                      1 "$rc"
refute "without starting it"                "MOSH_ARGS" "$out"
keys 'y\n'; out=$(DEV_TTY="$cs/keys" C fresco)
check  "on a terminal it offers to start it" "Start it in $DEV_PROJECTS_DIR/fresco? [y/N]" "$out"
check  "and yes starts it in the project"    "tmux new -A -s fresco -c $DEV_PROJECTS_DIR/fresco" "$out"
keys 'n\n'; out=$(DEV_TTY="$cs/keys" C fresco); rc=$?
refute "no leaves it alone"                  "MOSH_ARGS" "$out"
check_rc "and exits 1"                       1 "$rc"
keys '\n'; refute "so does just enter"       "MOSH_ARGS" "$(DEV_TTY="$cs/keys" C fresco)"
keys 'y\n'; out=$(DEV_TTY="$cs/keys" C scratchpad)
check  "a name with no folder starts plain"  "tmux new -A -s scratchpad" "$out"
refute "with no start folder"                " -c " "$out"
keys 'y\n'; out=$(DEV_TTY="$cs/keys" C my.proj)
check  "dots become underscores"             "-s my_proj" "$out"
refute "and a changed name gets no folder"   " -c " "$out"
out=$(C magpie extra); rc=$?
check  "nothing may follow the name"         "takes nothing after the name" "$out"
check_rc "exits 1"                           1 "$rc"
refute "a command is still a command"        "tmux new" "$(C ls)"

echo "matching what was typed"
M() { bash -c '. "$HOME/.local/lib/dev/_match.sh"; "$@"' _ "$@"; }
check "a swap of neighbours is one edit"    "1" "$(M _distance magpei magpie)"
check "a missing letter is one"             "1" "$(M _distance doctr doctor)"
check "the same word is none"               "0" "$(M _distance main main)"
check "and kitten/sitting is the classic 3" "3" "$(M _distance kitten sitting)"
check "short words get one slip"            "1" "$(M _typo_limit ls)"
check "longer ones two"                     "2" "$(M _typo_limit magpie)"
check "the same word, any case, comes first" "magpie" "$(M _best_matches MAGPIE magpie magpie-old)"
check "then a start"                        $'magpie\nmaps' "$(M _best_matches ma magpie maps fresco)"
check "then anywhere in it"                 "my_fresco" "$(M _best_matches resc main my_fresco)"
check "then the closest typo"               "magpie" "$(M _best_matches magpei main magpie fresco)"
check "only at the smallest distance"       "fresco" "$(M _best_matches fresko fresco frisks)"
out=$(M _best_matches zzzz main magpie); rc=$?
check "nothing close prints nothing"        "<none>" "${out}<none>"
check_rc "and fails"                        1 "$rc"

echo "connect: a near-miss of a command is a typo, unless that session exists"
running main
out=$(C doctr); rc=$?
check  "suggests the command"                "did you mean 'dev doctor'" "$out"
refute "and does not offer a session"        "no session" "$out"
check_rc "exits 1"                           1 "$rc"
refute "and attaches nothing"                "MOSH_ARGS" "$out"
running main doctr
check  "an existing session by that name is attached" "tmux new -A -s doctr" "$(C doctr)"
running main
check  "a swapped pair in a command is a typo too" "did you mean 'dev doctor'" "$(C dcotor)"

echo "connect: dev <name> finds the session meant"
running main magpie fresco
out=$(C magpei)
check  "a typo attaches the session meant" "tmux new -A -s magpie" "$out"
check  "and says which"                    "magpei → magpie" "$out"
check  "so does another case"              "tmux new -A -s magpie" "$(C MagPie)"
check  "and the start of a name"           "tmux new -A -s magpie" "$(C mag)"
running "main|0" "magpie|1" "maps|0"
out=$(C ma); rc=$?
check  "a name several could mean lists them" "'ma' could be any of: main magpie maps" "$out"
check_rc "and exits 1 without a terminal"  1 "$rc"
refute "attaching nothing"                 "MOSH_ARGS" "$out"
keys '\033[B\n'; out=$(DEV_TTY="$cs/keys" C ma)
check  "on a terminal they are picked from" "tmux new -A -s magpie" "$out"
check  "and only they are listed"          "'ma' could be any of these:" "$out"
running
out=$(C main)
check  "main is started when it is not running" "tmux new -A -s main" "$out"
refute "without asking"                    "Start it" "$out"
check  "in any case"                       "tmux new -A -s main" "$(C Main)"
running main
keys 'y\n'; out=$(DEV_TTY="$cs/keys" C fresko)
check  "a missing session finds the project meant" "Start 'fresco' in $DEV_PROJECTS_DIR/fresco? [y/N]" "$out"
check  "and starts it there"               "tmux new -A -s fresco -c $DEV_PROJECTS_DIR/fresco" "$out"
check  "without a terminal it names the project" "run dev fresco in a terminal" "$(C fresko)"

echo "connect: dev connect picks from a list"
check  "the filter matches anywhere, any case" $'fresco|1\nmy_fresh|0' \
    "$(bash -c '. "$HOME/.local/lib/dev/connect.sh"; _filter_sessions FRES "main|0" "fresco|1" "my_fresh|0"')"
check  "an empty filter keeps everything" $'main|0\nfresco|1' \
    "$(bash -c '. "$HOME/.local/lib/dev/connect.sh"; _filter_sessions "" "main|0" "fresco|1"')"
running "main|0" "fresco|1" "magpie|0"
pick() { keys "$1"; DEV_TTY="$cs/keys" C connect; }
out=$(pick '\n')
check  "enter takes the first"           "tmux new -A -s main" "$out"
check  "the list has a filter line"      "session:" "$out"
check  "attached sessions are marked"    "fresco (attached)" "$out"
check  "and it leaves no trace"          $'\033[J\033[?25h' "$out"
check  "down moves the selection"        "tmux new -A -s fresco" "$(pick '\033[B\n')"
check  "and up moves it back"            "tmux new -A -s fresco" "$(pick '\033[B\033[B\033[A\n')"
check  "it stops at the last"            "tmux new -A -s magpie" "$(pick '\033[B\033[B\033[B\033[B\n')"
check  "ctrl-n moves down too"           "tmux new -A -s fresco" "$(pick '\016\n')"
check  "typing filters"                  "tmux new -A -s magpie" "$(pick 'mag\n')"
check  "letters in order find it too"    "tmux new -A -s magpie" "$(pick 'mgp\n')"
check  "after the plain matches" $'fresco|1\nmy_fresh|0\nfaraway_resco|0' \
    "$(bash -c '. "$HOME/.local/lib/dev/connect.sh"; _filter_sessions fres "faraway_resco|0" "fresco|1" "my_fresh|0"')"
check  "a typed * is only a star"        "a*b|0" \
    "$(bash -c '. "$HOME/.local/lib/dev/connect.sh"; _filter_sessions "a*" "a*b|0" "axb|0"')"
check  "in any case"                     "tmux new -A -s magpie" "$(pick 'MAG\n')"
check  "backspace widens it again"       "tmux new -A -s fresco" "$(pick 'zz\177\177fr\n')"
out=$(pick 'zzz\n'); rc=$?
check  "no match says so"                "no session matches" "$out"
refute "and enter attaches nothing"      "MOSH_ARGS" "$out"
check_rc "running out of keys cancels"   1 "$rc"
out=$(pick '\033'); rc=$?
refute "esc cancels"                     "MOSH_ARGS" "$out"
check_rc "with exit 1"                   1 "$rc"
running
check  "with nothing running it says so" "no sessions on mini" "$(pick '\n')"
out=$(running main; C connect); rc=$?
check  "without a terminal it says why"  "needs a terminal" "$out"
check_rc "and exits 1"                   1 "$rc"
out=$(C connect fresco); rc=$?
check  "connect takes no name"           "takes no name" "$out"
check_rc "exits 1"                       1 "$rc"
rm -rf "$cs"

echo "unreachable"
cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
exit 255
STUB
chmod +x "$stub_dir/ssh"
out=$("$DEV" 2>&1); rc=$?
check "connect fails with a useful message" "cannot reach" "$out"
check_rc "connect exits 1 when unreachable" 1 "$rc"
out=$("$DEV" ls 2>&1); rc=$?;       check_rc "ls exits 1 when unreachable" 1 "$rc"

echo "pair: folder json"
# add-json does NOT merge with defaults — every field omitted becomes a Go zero
# value. These two silently break sync if left out, so assert them explicitly.
DEV_HOST=mini DEV_SESSION=main HOME="$HOME" bash -c '
  DEV_FOLDER_PATH=$HOME/.claude
  . "$HOME/.local/lib/dev/pair.sh"
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
# yadm stub. land's dotfiles branch is NOT scoped by PROJECTS_DIR — it always
# targets the real repo — so without this the accept-path test pushes the user's
# actual dotfiles to GitHub. Report zero commits ahead and refuse to push.
cat > "$stub_dir/yadm" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    rev-list) echo 0 ;;
    push)     echo "TEST BUG: land tried to push the real dotfiles repo" >&2; exit 1 ;;
    *)        exit 0 ;;
esac
STUB
chmod +x "$stub_dir/ssh" "$stub_dir/yadm"

out=$(printf 'n\n' | PROJECTS_DIR="$land_fix/p" "$DEV" land 2>&1)
check "land finds the repo that is ahead" "ahead (1 commit(s))" "$out"
check "land reports the dirty repo" "dirtyrepo — uncommitted changes" "$out"
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
out=$(printf 'y\n' | PROJECTS_DIR="$land_fix/p" "$DEV" land 2>&1)
check "accepting reports the push" "ahead pushed" "$out"
remote_head=$(git -C "$land_fix/up.git" rev-parse main 2>/dev/null)
local_head=$(git -C "$land_fix/p/ahead" rev-parse HEAD 2>/dev/null)
if [ "$remote_head" = "$local_head" ]; then
    printf '  ✓ the commit really reached the remote\n'; pass=$((pass+1))
else
    printf '  ✗ accepting did not push\n'; fail=$((fail+1))
fi
check "dirty repo still not pushed" "dirtyrepo — uncommitted changes" "$out"
refute "never touches the real dotfiles repo" "TEST BUG" "$out"
rm -rf "$land_fix"

echo "remote commands arrive intact"
# The stubs above echo their arguments, which hid a bug: real ssh joins them
# with spaces and the Mini's login shell (fish) splits the result again, so
# `ssh mini bash -lc "syncthing cli show system"` ran a bare `syncthing`, and
# `dev run echo hello world` printed nothing. This stub behaves like the real
# thing: drop options and host, join the rest, hand it to fish, stdin intact.
if have_fish=$(command -v fish); then
    remote=$(mktemp -d); mkdir -p "$remote/home" "$remote/bin"
    # A throwaway home for the "Mini": its login bash puts the stubs first,
    # ahead of the real Homebrew tools path_helper would otherwise find.
    printf 'export PATH="%s/bin:$PATH"\n' "$remote" > "$remote/home/.bash_profile"
    cat > "$remote/bin/syncthing" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do printf '%s\n' "\$a"; done > "$remote/syncthing-args"
[ "\$*" = "cli show system" ] && printf '{\n  "myID": "PEER-DEVICE-ID",\n  "uptime": 1\n}\n'
exit 0
STUB
    cat > "$remote/ssh" <<STUB
#!/usr/bin/env bash
while [ \$# -gt 0 ]; do case \$1 in -o) shift 2 ;; -*) shift ;; *) shift; break ;; esac; done
[ "\${1:-}" = "--" ] && shift
HOME="$remote/home" exec "$have_fish" --no-config -c "\$*"
STUB
    chmod +x "$remote/ssh" "$remote/bin/syncthing"

    rrun() { PATH="$remote:$PATH" DEV_HOST=mini "$DEV" run "$@" 2>&1; }
    check "dev run keeps its arguments"   "hello world"                 "$(rrun echo hello world)"
    check "a single quote survives"        "it's fine"                   "$(rrun printf '%s' "it's fine")"
    check "\$ and backticks stay literal"  '$HOME and `date`'            "$(rrun printf '%s' '$HOME and `date`')"

    # pair's calls, through the same path.
    pair_remote() {
        PATH="$remote:$PATH" DEV_HOST=mini bash -c '
            debug() { :; }
            '"$(awk '/^remote_bash\(\)/,/^\}|; }$/' "$DEV")"'
            . "$HOME/.local/lib/dev/pair.sh"
            '"$1"
    }
    check "pair reads the peer's device id" "PEER-DEVICE-ID" "$(pair_remote '_device_id_remote')"
    pair_remote '_st_remote config devices add-json "$(_device_json "MY-ID" "Levs MacBook Air")"' >/dev/null
    sent=$(sed -n 5p "$remote/syncthing-args")
    check "the device json arrives as one argument" '"name":"Levs MacBook Air"' "$sent"
    if printf '%s' "$sent" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        printf '  ✓ and still parses as json\n'; pass=$((pass+1))
    else
        printf '  ✗ device json no longer parses: %s\n' "$sent"; fail=$((fail+1))
    fi
    rm -rf "$remote"
else
    printf '  - skipped: fish is not installed\n'
fi

echo "doctor: one line per check"
dl() { bash -c '. "$HOME/.local/lib/dev/doctor.sh"; _doctor_line "$@"' _ "$@"; }
check "a pass is the area, the message, then the mark" "[packages] tmux ✓" "$(dl packages ok tmux)"
check "a warning ends in its own mark"  "[server] no sessions ➞"  "$(dl server warn 'no sessions')"
check "a failure ends in a cross"       "[packages] mosh missing ✗" "$(dl packages fail 'mosh missing' 'brew bundle')"
check "and its remedy goes underneath"  $'✗\n    → brew bundle'      "$(dl packages fail 'mosh missing' 'brew bundle')"
check "no remedy, no second line"       "1"                         "$(dl shell ok 'dev installed' | wc -l | tr -d ' ')"
out=$(PATH="$stub_dir:$PATH" "$DEV" doctor 2>&1)
refute "the doctor no longer prints group headings" $'\nPackages\n' "$out"
check "every check is tagged with its area" "[dotfiles] " "$out"
check "a blank line separates areas" $'\n\n[dotfiles] ' "$out"
check "but none comes before the first" "[packages] " "${out:0:11}"

echo "doctor: a spinner while a slow check runs"
# _doctor_spin <tty> <command...>: stdout is the command's, fd 4 the terminal's.
spin() {
    local tty=$1; shift
    _DOCTOR_TTY=$tty bash -c '. "$HOME/.local/lib/dev/doctor.sh"
        _doctor_spin dotfiles "fetching origin" "$@"' _ "$@" 4>"$stub_dir/spin.tty"
}
out=$(spin 0 sh -c 'echo result; exit 3'); rc=$?
check    "without a terminal the output passes through" "result" "$out"
check_rc "and so does the exit code"                    3        "$rc"
check    "and nothing is drawn"                         "<none>" "$(cat "$stub_dir/spin.tty")<none>"
out=$(spin 1 sh -c 'sleep 0.3; echo result; exit 3'); rc=$?
tty_out=$(cat "$stub_dir/spin.tty")
check    "on a terminal the output still passes through" "result" "$out"
check_rc "and the exit code"                             3        "$rc"
check    "the spinner sits where the mark goes"          "[dotfiles] fetching origin ⠋" "$tty_out"
check    "and the line is cleared for the result"        $'\r\033[K' "$tty_out"
refute   "none of it lands in the output"                "fetching" "$out"
out=$(DEV_VERBOSE=1 spin 1 sh -c 'echo result')
check    "-v turns the spinner off"                      "<none>" "$(cat "$stub_dir/spin.tty")<none>"

echo "doctor: Tailscale from the app or from brew"
ts_dir=$(mktemp -d); mkdir -p "$ts_dir/bin" "$ts_dir/Tailscale.app/Contents/MacOS"
# A tailscale CLI whose `status` behaves as $TS_MODE says: ok, stale or down.
cat > "$ts_dir/bin/tailscale" <<'STUB'
#!/usr/bin/env bash
case "${TS_MODE:-ok}" in
    stale) echo 'Warning: client version "1.102.5" != tailscaled server version "1.102.4"' >&2 ;;
    down)  echo 'failed to connect to local tailscaled' >&2; exit 1 ;;
esac
echo "100.94.57.78   mini   macOS   -"
STUB
cp "$ts_dir/bin/tailscale" "$ts_dir/Tailscale.app/Contents/MacOS/Tailscale"
chmod +x "$ts_dir/bin/tailscale" "$ts_dir/Tailscale.app/Contents/MacOS/Tailscale"
ts() { bash -c '. "$HOME/.local/lib/dev/doctor.sh"; "$@"' _ "$@"; }
no_app="$ts_dir/none.app"
check "the app is found by its bundle" "app $ts_dir/Tailscale.app/Contents/MacOS/Tailscale" \
    "$(DEV_TAILSCALE_APP="$ts_dir/Tailscale.app" PATH="$ts_dir/bin:$PATH" ts _tailscale_install)"
check "brew's CLI is found on PATH"    "brew $ts_dir/bin/tailscale" \
    "$(DEV_TAILSCALE_APP="$no_app" PATH="$ts_dir/bin:$PATH" ts _tailscale_install)"
DEV_TAILSCALE_APP="$no_app" PATH="$ts_dir/empty:/usr/bin:/bin" ts _tailscale_install >/dev/null; rc=$?
check_rc "neither is not installed"    1 "$rc"
check "a working daemon is ok"         "ok"    "$(TS_MODE=ok    ts _tailscale_state "$ts_dir/bin/tailscale")"
check "a daemon behind its CLI is stale" "stale" "$(TS_MODE=stale ts _tailscale_state "$ts_dir/bin/tailscale")"
check "no daemon is down"              "down"  "$(TS_MODE=down  ts _tailscale_state "$ts_dir/bin/tailscale")"
rm -rf "$ts_dir"

echo "doctor: reading syncthing's folders"
# The API pretty-prints ("fsWatcherEnabled": true), which the old grep for
# "fsWatcherEnabled":true never matched. Fixtures are pretty-printed on purpose.
cf_home=$(mktemp -d); mkdir -p "$cf_home/.claude"
cf() { printf '%s' "$1" | CLAUDE_DIR="$cf_home/.claude" bash -c '
    . "$HOME/.local/lib/dev/doctor.sh"; _claude_folders'; }
field() { printf '%s\n' "$1" | awk -v k="$2" '$1 == k { print $2 }'; }

healthy='[
  {
    "id": "claude-state",
    "path": "'"$cf_home"'/.claude",
    "devices": [ { "deviceID": "AIR" }, { "deviceID": "MINI" } ],
    "fsWatcherEnabled": true,
    "versioning": { "type": "staggered" }
  }
]'
out=$(cf "$healthy")
check "a watched folder reads as watched"     "1"         "$(field "$out" watcher)"
check "staggered versioning is reported"      "staggered" "$(field "$out" versioning)"
check "shared with both devices"              "2"         "$(field "$out" devices)"

# What this Air actually had: a hand-made folder given as ~/.claude and the
# one dev pair created, given as an absolute path — the same directory.
duplicate='[
  {
    "id": "3khhq-ijoxl",
    "path": "'"$cf_home"'/.claude/",
    "devices": [ { "deviceID": "AIR" } ],
    "fsWatcherEnabled": false,
    "versioning": { "type": "" }
  },
  {
    "id": "claude-state",
    "path": "'"$cf_home"'/.claude",
    "devices": [ { "deviceID": "AIR" }, { "deviceID": "MINI" } ],
    "fsWatcherEnabled": true,
    "versioning": { "type": "staggered" }
  }
]'
out=$(cf "$duplicate")
check "two folders on one path are counted"   "2"            "$(field "$out" count)"
check "the shared one is the one reported"    "claude-state" "$(field "$out" id)"

unwatched='[ { "id": "x", "path": "'"$cf_home"'/.claude", "devices": [ { "deviceID": "AIR" } ],
               "fsWatcherEnabled": false, "versioning": { "type": "" } } ]'
out=$(cf "$unwatched")
check "an unwatched folder reads as unwatched" "0"    "$(field "$out" watcher)"
check "no versioning reads as none"            "none" "$(field "$out" versioning)"
check "shared with nobody"                     "1"    "$(field "$out" devices)"

out=$(cf '[ { "id": "photos", "path": "/Volumes/photos", "devices": [], "fsWatcherEnabled": true } ]')
check "other folders are not ~/.claude"        "0"    "$(field "$out" count)"
rm -rf "$cf_home"

echo "repos: the list and cloning it"
rp=$(mktemp -d); mkdir -p "$rp/projects" "$rp/upstream"
for r in alpha beta; do
    git init -q --bare "$rp/upstream/$r.git"
    git clone -q "$rp/upstream/$r.git" "$rp/seed-$r" 2>/dev/null
    ( cd "$rp/seed-$r" && git config user.email t@t && git config user.name t \
      && echo "$r" > README && git add . && git commit -qm init && git branch -M main \
      && git push -q origin main ) >/dev/null 2>&1
done
R() { DEV_REPOS_FILE="$rp/repos" DEV_PROJECTS_DIR="$rp/projects" "$DEV" repos "$@" 2>&1; }

out=$(R list); rc=$?
check "no list yet is explained, not an error" "no repo list yet" "$out"
check_rc "and exits 0" 0 "$rc"

printf '# only a comment\n' > "$rp/repos"
out=$(R list); rc=$?
check "an empty list says so" "the repo list is empty" "$out"
check_rc "and exits 0" 0 "$rc"
rm "$rp/repos"

out=$(R add "file://$rp/upstream/alpha.git")
check "add takes the name from the URL" "added alpha" "$out"
check "and says how it travels" "yadm encrypt" "$out"
check "the file is owner-only" "600" "$(stat -f %Lp "$rp/repos")"
out=$(R add --as betty "file://$rp/upstream/beta.git")
check "add --as sets the folder name" "added betty" "$out"
out=$(R add "file://$rp/upstream/alpha")
check "the same repo again is a no-op" "alpha is already listed" "$out"
out=$(R add --as alpha "file://$rp/upstream/beta.git"); rc=$?
check "a clashing name is refused" "alpha is already listed as" "$out"
check_rc "and exits 1" 1 "$rc"
out=$(R add --as ../escape "file://$rp/upstream/beta.git"); rc=$?
check "a name with a slash is refused" "not usable as a folder name" "$out"
out=$(R add not-a-thing); rc=$?
check "an unknown name is refused" "neither a URL nor a git repo" "$out"
out=$(R add --as x "file://$rp/upstream/alpha.git" "file://$rp/upstream/beta.git"); rc=$?
check "--as takes exactly one URL" "one repo at a time" "$out"
check_rc "and exits 1" 1 "$rc"
out=$(R add); rc=$?
check "add with nothing explains usage" "usage: dev repos add" "$out"

out=$(R status); rc=$?
check "status names what is missing" "alpha — not cloned" "$out"
check_rc "status exits 2 when something is missing" 2 "$rc"

out=$(R sync); rc=$?
check "sync clones alpha" "cloned alpha" "$out"
check "sync clones betty" "cloned betty" "$out"
check_rc "sync exits 0" 0 "$rc"
check "the clone has the right contents" "beta" "$(cat "$rp/projects/betty/README" 2>/dev/null)"
out=$(R status); rc=$?
check_rc "status exits 0 once everything is here" 0 "$rc"
out=$(R sync)
check "a second sync has nothing to do" "everything listed is already here" "$out"

# Never touch a folder that is already there.
rm -rf "$rp/projects/alpha" && mkdir "$rp/projects/alpha" && echo mine > "$rp/projects/alpha/notes"
git -C "$rp/projects/betty" remote set-url origin "file://$rp/elsewhere.git"
out=$(R sync)
check "a non-repo folder is left alone" "alpha left alone" "$out"
check "its contents survive" "mine" "$(cat "$rp/projects/alpha/notes")"
check "a clone with another origin is left alone" "betty left alone" "$out"
out=$(R list)
check "list flags the non-repo folder" "exists but is not a git repo" "$out"
check "list flags the other origin" "has a different origin" "$out"

# add from an existing clone, by name: reads its origin.
git clone -q "$rp/upstream/alpha.git" "$rp/projects/gamma" 2>/dev/null
out=$(R add gamma)
check "add <name> reads the clone's origin" "added gamma  $rp/upstream/alpha.git" "$out"
git init -q "$rp/projects/loner"
out=$(R add loner); rc=$?
check "a clone with no remote is refused" "has no origin remote" "$out"

printf '# my own comment\n' >> "$rp/repos"
out=$(R remove betty)
check "remove drops the entry" "removed betty" "$out"
check "and says the clone is untouched" "itself is untouched" "$out"
check "the clone really is still there" "yes" "$([ -d "$rp/projects/betty" ] && echo yes)"
check "comments survive a remove" "# my own comment" "$(cat "$rp/repos")"
check "the file stays owner-only" "600" "$(stat -f %Lp "$rp/repos")"
out=$(R remove betty); rc=$?
check "removing an unknown name is refused" "not in the list" "$out"
out=$(R delete alpha); rc=$?
check "delete is not a command" "unknown: dev repos delete" "$out"
check_rc "and exits 1" 1 "$rc"
check "an unknown subcommand shows the usage" "dev repos add <entry>..." "$out"

# Several entries at once; a bad one does not stop the rest.
mr=$(mktemp -d); mkdir -p "$mr/projects"
M() { DEV_REPOS_FILE="$mr/repos" DEV_PROJECTS_DIR="$mr/projects" "$DEV" repos "$@" 2>&1; }
out=$(M add "file://$rp/upstream/alpha.git" nonsense "file://$rp/upstream/beta.git"); rc=$?
check "add takes several entries" "added alpha" "$out"
check "the entry after a bad one still lands" "added beta" "$out"
check "the bad one is named" "nonsense is neither a URL" "$out"
check_rc "a partly failed add exits 1" 1 "$rc"
check "the hint is printed once" "1" "$(printf '%s\n' "$out" | grep -c 'yadm encrypt')"
out=$(M remove alpha ghost beta); rc=$?
check "remove takes several names" "removed alpha" "$out"
check "the name after an unknown one is still removed" "removed beta" "$out"
check "the unknown one is named" "ghost is not in the list" "$out"
check_rc "a partly failed remove exits 1" 1 "$rc"
left=$(grep -E '^(alpha|beta) ' "$mr/repos"); check "both are gone from the file" "<none>" "${left:-<none>}"
out=$(M remove); rc=$?
check "remove with nothing explains usage" "usage: dev repos remove" "$out"
rm -rf "$mr"

out=$(R help); rc=$?
check "dev repos help describes add" "dev repos add <entry>..." "$out"
check "and --as" "dev repos add --as <name> <url>" "$out"
check "and remove" "dev repos remove <name>..." "$out"
check_rc "and exits 0" 0 "$rc"
check "dev help lists repos" "dev repos" "$("$DEV" help 2>&1)"

# GitHub URLs go through gh, which brings its own login.
mkdir -p "$rp/bin"
cat > "$rp/bin/gh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "repo clone") echo "gh \$*" >> "$rp/gh-calls"; git init -q "\$4"
                git -C "\$4" remote add origin "\$3"; exit 0 ;;
esac
STUB
chmod +x "$rp/bin/gh"
out=$(PATH="$rp/bin:$PATH" R add https://github.com/someone/private-thing)
out=$(PATH="$rp/bin:$PATH" R sync)
check "github repos are cloned with gh" "gh repo clone https://github.com/someone/private-thing $rp/projects/private-thing" "$(cat "$rp/gh-calls" 2>/dev/null)"
check "and reported" "cloned private-thing" "$out"
rm -rf "$rp"

echo "is_server reads the sleep setting itself"
# pmset lists displaysleep before sleep; matching /sleep/ read displaysleep.
ps_dir=$(mktemp -d)
# Its own ssh stub: earlier sections replace the shared one with a silent one.
printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = true ] && exit 0; done\necho "SSH_ARGS: $*"\n' > "$ps_dir/ssh"
chmod +x "$ps_dir/ssh"
pm() { printf '#!/usr/bin/env bash\nprintf "%s"\n' "$1" > "$ps_dir/pmset"; chmod +x "$ps_dir/pmset"; }
pm ' displaysleep         10\n sleep                0\n disksleep            0\n'
out=$(PATH="$ps_dir:$PATH" "$DEV" run echo on-the-server 2>&1)
check "sleep 0 behind displaysleep 10 is the server" "on-the-server" "$out"
refute "and runs locally, not over ssh" "SSH_ARGS" "$out"
pm ' displaysleep         0\n sleep                1 (sleep prevented by powerd)\n'
out=$(PATH="$ps_dir:$PATH" "$DEV" run echo elsewhere 2>&1)
check "sleep 1 is not the server, even with displaysleep 0" "SSH_ARGS" "$out"
rm -rf "$ps_dir"

echo "verbose"
vb=$(mktemp -d)
cat > "$vb/ssh" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = true ] && exit 0; done
case "\$*" in *"has-session -t =magpie"*) exit 0 ;; *has-session*) exit 1 ;; esac
if [ "\${*: -1}" = "bash -ls" ]; then
    in=\$(cat)
    case "\$in" in *"tmux ls"*) echo "magpie|0" ;; *) printf 'SSH_STDIN: %s\n' "\$in" ;; esac
    exit 0
fi
echo "SSH_ARGS: \$*"
STUB
printf '#!/usr/bin/env bash\necho "MOSH_ARGS: $*"\n' > "$vb/mosh"
chmod +x "$vb/ssh" "$vb/mosh"
V() { PATH="$vb:$PATH" "$DEV" "$@"; }

quiet=$(V ls 2>&1)
check "without -v there is no debug output" "<none>" "$(printf '%s' "$quiet" | grep '\[dev\]' || echo '<none>')"
out=$(V -v ls 2>/dev/null)
check "-v leaves stdout as it was" "$quiet" "$out"
err=$(V -v ls 2>&1 >/dev/null)
check "-v narrates on stderr" "[dev] this machine is a client" "$err"
check "-v shows the remote calls" '[dev] $ ssh -o BatchMode=yes mini' "$err"
check "including silenced ones" '[dev] $ ssh -o ConnectTimeout=5 -o BatchMode=yes mini true' "$err"
check "--verbose is the same" "[dev] this machine is a client" "$(V --verbose ls 2>&1 >/dev/null)"
check "so is DEV_VERBOSE=1" "[dev] this machine is a client" "$(DEV_VERBOSE=1 V ls 2>&1 >/dev/null)"

out=$(V run echo -v 2>&1)
check "a -v after the command belongs to it" "SSH_STDIN: echo -v" "$out"
check "and does not turn on verbose" "<none>" "$(printf '%s' "$out" | grep '\[dev\]' || echo '<none>')"

err=$(V -v run curl -H 'X-API-Key: s3cr3t' http://127.0.0.1:8384 2>&1 >/dev/null)
check "the command sent is shown" "sending to mini's bash: curl" "$err"
refute "an API key is masked" "s3cr3t" "$err"
check "and marked as masked" "X-API-Key:" "$err"

err=$(V -v magpie 2>&1 >/dev/null)
check "connect says the session exists" "'magpie' exists on mini: attaching" "$err"
check "and the command it runs" '[dev] $ mosh mini -- tmux new -A -s magpie' "$err"
err=$(cd "$DEV_PROJECTS_DIR/fresco" && V -v 2>&1 >/dev/null)
check "connect says why a folder's session was passed over" "no 'fresco' session on mini for $DEV_PROJECTS_DIR/fresco: 'main' instead" "$err"
err=$(V -v my.proj 2>&1 >/dev/null)
check "connect explains a renamed session" "renamed 'my.proj' to 'my_proj'" "$err"
err=$(cd "$DEV_PROJECTS_DIR" && V -v 2>&1 >/dev/null)
check "connect explains the default" "names no session: 'main', the default" "$err"

# Tools are logging functions in verbose mode; `have` must not mistake one
# for an installed program.
out=$(PATH="$vb:/usr/bin:/bin:/usr/sbin:/sbin" "$DEV" -v pair 2>&1); rc=$?
check "a missing tool is still missing under -v" "syncthing not installed" "$out"
check_rc "and pair stops" 1 "$rc"
rm -rf "$vb"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
