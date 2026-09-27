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
# which session `mini` picks does not depend on where the suite was started.
export MINI_PROJECTS_DIR="$stub_dir/projects"
mkdir -p "$MINI_PROJECTS_DIR"
cd "$stub_dir" || exit 1

echo "dispatch"
out=$("$MINI" help 2>&1);            check "help lists subcommands" "mini preflight" "$out"
out=$("$MINI" bogus 2>&1); rc=$?;    check "a non-command is a session" "tmux new -A -s bogus" "$out"
check_rc "and attaching exits 0" 0 "$rc"
out=$("$MINI" -x 2>&1); rc=$?;       check "an unknown option is refused" "unknown option '-x'" "$out"
check_rc "and exits 1" 1 "$rc"

echo "run"
# What goes over the wire. Whether it arrives intact on a real login shell is
# checked by "remote commands arrive intact" below.
out=$("$MINI" run echo hello 2>&1);  check "run uses a login shell" "bash -ls" "$out"
check "run sends the command on stdin" "SSH_STDIN: echo hello" "$out"
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

echo "sessions by name, and by folder"
mkdir -p "$MINI_PROJECTS_DIR/fresco/Sources" "$MINI_PROJECTS_DIR/my.proj"
out=$(cd "$MINI_PROJECTS_DIR/fresco/Sources" && "$MINI" 2>&1)
check "mini in a project is that project's session" "tmux new -A -s fresco" "$out"
check "started in the project folder" "-c $MINI_PROJECTS_DIR/fresco" "$out"
out=$(cd "$MINI_PROJECTS_DIR" && "$MINI" 2>&1)
check "the projects folder itself is main" "tmux new -A -s main" "$out"
refute "with no start folder" " -c " "$out"
out=$("$MINI" 2>&1)
check "mini elsewhere is main" "tmux new -A -s main" "$out"
out=$("$MINI" fresco 2>&1)
check "mini <project> starts in the project too" "-s fresco -c $MINI_PROJECTS_DIR/fresco" "$out"
out=$("$MINI" magpie 2>&1)
check "a name with no folder is just a session" "tmux new -A -s magpie" "$out"
refute "with no start folder" " -c " "$out"
out=$("$MINI" my.proj 2>&1)
check "dots become underscores" "-s my_proj" "$out"
refute "and a changed name gets no folder" " -c " "$out"
out=$("$MINI" "two words" 2>&1)
check "so do spaces" "-s two_words" "$out"
out=$("$MINI" connect run 2>&1)
check "connect takes a name that is a command" "tmux new -A -s run" "$out"
out=$("$MINI" ls 2>&1)
refute "a command is still a command" "tmux new" "$out"

echo "a near-miss of a command is a typo, unless that session exists"
typo=$(mktemp -d)
cat > "$typo/ssh" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = true ] && exit 0; done
case "\$*" in *"has-session -t =doctr"*) [ -f "$typo/exists" ]; exit \$? ;; esac
echo "SSH_ARGS: \$*"
STUB
chmod +x "$typo/ssh"
out=$(PATH="$typo:$PATH" "$MINI" doctr 2>&1); rc=$?
check "suggests the command" "did you mean 'mini doctor'" "$out"
check "and how to start the session anyway" "mini connect doctr" "$out"
check_rc "exits 1" 1 "$rc"
refute "and attaches nothing" "MOSH_ARGS" "$out"
touch "$typo/exists"
out=$(PATH="$typo:$PATH" "$MINI" doctr 2>&1)
check "an existing session by that name is attached" "tmux new -A -s doctr" "$out"
rm -rf "$typo"

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

out=$(printf 'n\n' | PROJECTS_DIR="$land_fix/p" "$MINI" land 2>&1)
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
refute "never touches the real dotfiles repo" "TEST BUG" "$out"
rm -rf "$land_fix"

echo "remote commands arrive intact"
# The stubs above echo their arguments, which hid a bug: real ssh joins them
# with spaces and the Mini's login shell (fish) splits the result again, so
# `ssh mini bash -lc "syncthing cli show system"` ran a bare `syncthing`, and
# `mini run echo hello world` printed nothing. This stub behaves like the real
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

    rrun() { PATH="$remote:$PATH" MINI_HOST=mini "$MINI" run "$@" 2>&1; }
    check "mini run keeps its arguments"   "hello world"                 "$(rrun echo hello world)"
    check "a single quote survives"        "it's fine"                   "$(rrun printf '%s' "it's fine")"
    check "\$ and backticks stay literal"  '$HOME and `date`'            "$(rrun printf '%s' '$HOME and `date`')"

    # pair's calls, through the same path.
    pair_remote() {
        PATH="$remote:$PATH" MINI_HOST=mini bash -c '
            debug() { :; }
            '"$(awk '/^remote_bash\(\)/,/^\}|; }$/' "$MINI")"'
            . "$HOME/.local/lib/mini/pair.sh"
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

echo "doctor: reading syncthing's folders"
# The API pretty-prints ("fsWatcherEnabled": true), which the old grep for
# "fsWatcherEnabled":true never matched. Fixtures are pretty-printed on purpose.
cf_home=$(mktemp -d); mkdir -p "$cf_home/.claude"
cf() { printf '%s' "$1" | CLAUDE_DIR="$cf_home/.claude" bash -c '
    . "$HOME/.local/lib/mini/doctor.sh"; _claude_folders'; }
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
# one mini pair created, given as an absolute path — the same directory.
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
R() { MINI_REPOS_FILE="$rp/repos" MINI_PROJECTS_DIR="$rp/projects" "$MINI" repos "$@" 2>&1; }

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
check "add with nothing explains usage" "usage: mini repos add" "$out"

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
check "delete is not a command" "unknown: mini repos delete" "$out"
check_rc "and exits 1" 1 "$rc"
check "an unknown subcommand shows the usage" "mini repos add <entry>..." "$out"

# Several entries at once; a bad one does not stop the rest.
mr=$(mktemp -d); mkdir -p "$mr/projects"
M() { MINI_REPOS_FILE="$mr/repos" MINI_PROJECTS_DIR="$mr/projects" "$MINI" repos "$@" 2>&1; }
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
check "remove with nothing explains usage" "usage: mini repos remove" "$out"
rm -rf "$mr"

out=$(R help); rc=$?
check "mini repos help describes add" "mini repos add <entry>..." "$out"
check "and --as" "mini repos add --as <name> <url>" "$out"
check "and remove" "mini repos remove <name>..." "$out"
check_rc "and exits 0" 0 "$rc"
check "mini help lists repos" "mini repos" "$("$MINI" help 2>&1)"

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
out=$(PATH="$ps_dir:$PATH" "$MINI" run echo on-the-server 2>&1)
check "sleep 0 behind displaysleep 10 is the server" "on-the-server" "$out"
refute "and runs locally, not over ssh" "SSH_ARGS" "$out"
pm ' displaysleep         0\n sleep                1 (sleep prevented by powerd)\n'
out=$(PATH="$ps_dir:$PATH" "$MINI" run echo elsewhere 2>&1)
check "sleep 1 is not the server, even with displaysleep 0" "SSH_ARGS" "$out"
rm -rf "$ps_dir"

echo "verbose"
vb=$(mktemp -d)
cat > "$vb/ssh" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = true ] && exit 0; done
case "\$*" in *"has-session -t =magpie"*) exit 0 ;; *has-session*) exit 1 ;; esac
[ "\${*: -1}" = "bash -ls" ] && { printf 'SSH_STDIN: %s\n' "\$(cat)"; exit 0; }
echo "SSH_ARGS: \$*"
STUB
printf '#!/usr/bin/env bash\necho "MOSH_ARGS: $*"\n' > "$vb/mosh"
chmod +x "$vb/ssh" "$vb/mosh"
V() { PATH="$vb:$PATH" "$MINI" "$@"; }

quiet=$(V ls 2>&1)
check "without -v there is no debug output" "<none>" "$(printf '%s' "$quiet" | grep '\[mini\]' || echo '<none>')"
out=$(V -v ls 2>/dev/null)
check "-v leaves stdout as it was" "$quiet" "$out"
err=$(V -v ls 2>&1 >/dev/null)
check "-v narrates on stderr" "[mini] this machine is a client" "$err"
check "-v shows the remote calls" '[mini] $ ssh -o BatchMode=yes mini' "$err"
check "including silenced ones" '[mini] $ ssh -o ConnectTimeout=5 -o BatchMode=yes mini true' "$err"
check "--verbose is the same" "[mini] this machine is a client" "$(V --verbose ls 2>&1 >/dev/null)"
check "so is MINI_VERBOSE=1" "[mini] this machine is a client" "$(MINI_VERBOSE=1 V ls 2>&1 >/dev/null)"

out=$(V run echo -v 2>&1)
check "a -v after the command belongs to it" "SSH_STDIN: echo -v" "$out"
check "and does not turn on verbose" "<none>" "$(printf '%s' "$out" | grep '\[mini\]' || echo '<none>')"

err=$(V -v run curl -H 'X-API-Key: s3cr3t' http://127.0.0.1:8384 2>&1 >/dev/null)
check "the command sent is shown" "sending to mini's bash: curl" "$err"
refute "an API key is masked" "s3cr3t" "$err"
check "and marked as masked" "X-API-Key:" "$err"

err=$(V -v magpie 2>&1 >/dev/null)
check "connect says where the name came from" "session 'magpie' from the name given" "$err"
check "and whether it exists" "'magpie' exists on mini: attaching" "$err"
check "and the command it runs" '[mini] $ mosh mini -- tmux new -A -s magpie' "$err"
err=$(cd "$MINI_PROJECTS_DIR/fresco" && V -v 2>&1 >/dev/null)
check "connect names the project folder" "from the project folder you are in" "$err"
check "and the start folder" "if it has to be created, it starts in $MINI_PROJECTS_DIR/fresco" "$err"
check "and a missing session" "'fresco' does not exist on mini: creating it" "$err"
err=$(V -v my.proj 2>&1 >/dev/null)
check "connect explains a renamed session" "renamed 'my.proj' to 'my_proj'" "$err"
err=$(V -v 2>&1 >/dev/null)
check "connect explains the default" "session 'main', the default" "$err"

# Tools are logging functions in verbose mode; `have` must not mistake one
# for an installed program.
out=$(PATH="$vb:/usr/bin:/bin:/usr/sbin:/sbin" "$MINI" -v pair 2>&1); rc=$?
check "a missing tool is still missing under -v" "syncthing not installed" "$out"
check_rc "and pair stops" 1 "$rc"
rm -rf "$vb"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
