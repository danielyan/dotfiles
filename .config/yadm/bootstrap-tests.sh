#!/usr/bin/env bash
# Tests for bootstrap's GitHub key registration.
# Run: bash ~/.config/yadm/bootstrap-tests.sh
#
# Extracts register_github_key from bootstrap and exercises it against a stubbed
# `gh`. The real bug this covers: a failed upload used to be invisible, and was
# never retried because it sat inside the "key does not exist yet" branch.

set -uo pipefail
BOOTSTRAP="$HOME/.config/yadm/bootstrap"
pass=0; fail=0

check() {
    if [[ "$3" == *"$2"* ]]; then printf '  ✓ %s\n' "$1"; pass=$((pass+1))
    else printf '  ✗ %s\n      want: %s\n      got:  %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
refute() {
    if [[ "$3" != *"$2"* ]]; then printf '  ✓ %s\n' "$1"; pass=$((pass+1))
    else printf '  ✗ %s (unexpectedly found: %s)\n' "$1" "$2"; fail=$((fail+1)); fi
}

# $1 = gh stub body, $2 = answer to ask() prompts
run_case() {
    local tmp; tmp=$(mktemp -d)
    mkdir -p "$tmp/.ssh"
    echo "ssh-ed25519 AAAAKEYBODY123 ldan@host" > "$tmp/.ssh/id_ed25519.pub"
    # An empty stub body means "gh is not installed": create no stub, and use a
    # PATH that cannot reach the real one.
    local path="$tmp:$PATH"
    if [ -n "$1" ]; then
        printf '%s\n' "$1" > "$tmp/gh"; chmod +x "$tmp/gh"
    else
        path="$tmp:/usr/bin:/bin"
    fi

    HOME="$tmp" PATH="$path" ANSWER="$2" bash -c '
        echo_ok()   { echo "[ok] $1"; }
        echo_err()  { echo "[err] $1"; }
        echo_warn() { echo "[warn] $1"; }
        command_exists() { command -v "$1" >/dev/null 2>&1; }
        ask() { [ "$ANSWER" = "y" ]; }
        TODOS=(); todo() { TODOS+=("$1"); echo_err "$1"; }
        HOSTLABEL=testhost
        '"$(awk "/^register_github_key\(\)/,/^\}/" "$BOOTSTRAP")"'
        register_github_key
        printf "TODOCOUNT:%d\n" "${#TODOS[@]}"
    ' 2>&1
    rm -rf "$tmp"
}

echo "key already on github"
out=$(run_case '#!/usr/bin/env bash
case "$1 $2" in
  "auth status") echo "Token scopes: '"'"'admin:public_key'"'"', repo"; exit 0 ;;
  "ssh-key list") echo "host	ssh-ed25519 AAAAKEYBODY123	2026	1	authentication"; exit 0 ;;
  "ssh-key add") echo "SHOULD NOT RUN"; exit 0 ;;
esac' y)
check "reports already registered" "already registered" "$out"
refute "does not re-add the key" "SHOULD NOT RUN" "$out"
check "records no todo" "TODOCOUNT:0" "$out"

echo "missing scope, user grants it"
out=$(run_case '#!/usr/bin/env bash
case "$1 $2" in
  "auth status") echo "Token scopes: '"'"'repo'"'"'"; exit 0 ;;
  "ssh-key list") exit 0 ;;
  "auth refresh") echo "refreshed"; exit 0 ;;
  "ssh-key add") echo "added"; exit 0 ;;
esac' y)
check "notices the missing scope" "lacks the admin:public_key scope" "$out"
check "refreshes then succeeds" "Registered SSH key" "$out"
check "records no todo on success" "TODOCOUNT:0" "$out"

echo "missing scope, user declines"
out=$(run_case '#!/usr/bin/env bash
case "$1 $2" in
  "auth status") echo "Token scopes: '"'"'repo'"'"'"; exit 0 ;;
  "ssh-key list") exit 0 ;;
esac' n)
check "records a todo" "TODOCOUNT:1" "$out"
check "todo names the refresh command" "gh auth refresh -h github.com -s admin:public_key" "$out"
check "todo names the retry command" "gh ssh-key add" "$out"

echo "upload fails outright"
out=$(run_case '#!/usr/bin/env bash
case "$1 $2" in
  "auth status") echo "Token scopes: '"'"'admin:public_key'"'"'"; exit 0 ;;
  "ssh-key list") exit 0 ;;
  "ssh-key add") echo "HTTP 404" >&2; exit 1 ;;
esac' y)
check "surfaces the failure" "Registering the SSH key failed" "$out"
check "records a retryable todo" "TODOCOUNT:1" "$out"

echo "gh not installed"
out=$(run_case '' y)
check "falls back to a manual instruction" "Add this machine's SSH key to GitHub" "$out"

# set_login_shell: $1 = shell dscl reports, $2 = sudo stub exit status
# chsh used to prompt for the account password itself, and a typo failed with
# nothing recorded. The stubs log calls so the tests can see what ran.
shell_case() {
    local tmp; tmp=$(mktemp -d)
    printf '#!/usr/bin/env bash\necho "UserShell: %s"\n' "$1" > "$tmp/dscl"
    printf '#!/usr/bin/env bash\necho "sudo $*" >> "%s/calls"\nexit %s\n' "$tmp" "$2" > "$tmp/sudo"
    chmod +x "$tmp/dscl" "$tmp/sudo"
    PATH="$tmp:$PATH" USER=testuser bash -c '
        echo_ok()   { echo "[ok] $1"; }
        echo_err()  { echo "[err] $1"; }
        TODOS=(); todo() { TODOS+=("$1"); echo_err "$1"; }
        '"$(awk "/^set_login_shell\(\)/,/^\}/" "$BOOTSTRAP")"'
        set_login_shell /opt/homebrew/bin/fish
        printf "TODOCOUNT:%d\n" "${#TODOS[@]}"
    ' 2>&1
    [ -f "$tmp/calls" ] && cat "$tmp/calls"
    rm -rf "$tmp"
}

echo "login shell already fish"
out=$(shell_case /opt/homebrew/bin/fish 0)
check  "reports it"            "fish is already the default shell" "$out"
refute "does not call chsh"    "sudo chsh"                         "$out"
check  "records no todo"       "TODOCOUNT:0"                       "$out"

echo "login shell is zsh"
out=$(shell_case /bin/zsh 0)
check "changes it via sudo"    "sudo chsh -s /opt/homebrew/bin/fish testuser" "$out"
check "records no todo"        "TODOCOUNT:0"                                  "$out"

echo "chsh fails"
out=$(shell_case /bin/zsh 1)
check "records a retryable todo" "Set fish as the login shell: sudo chsh -s /opt/homebrew/bin/fish testuser" "$out"
check "counts it"                "TODOCOUNT:1"                                                           "$out"

# enable_touchid_sudo, against a scratch pam file and fake modules.
# $1 = "tid" if the Touch ID module exists, $2 = "reattach" if Homebrew's
# pam_reattach exists, $3 = install stub exit, $4 = tee stub exit,
# $5 = pre-existing sudo_local content ("" for none), $6 = runs (default 1)
touchid_case() {
    local tmp; tmp=$(mktemp -d); mkdir "$tmp/bin" "$tmp/src"
    [ "$1" = tid ] && touch "$tmp/pam_tid.so.2"
    [ "$2" = reattach ] && echo "module-v1" > "$tmp/src/pam_reattach.so"
    [ -n "$5" ] && printf '%s\n' "$5" > "$tmp/sudo_local"
    # sudo runs its command unprivileged; install ignores ownership flags.
    printf '#!/usr/bin/env bash\nexec "$@"\n' > "$tmp/bin/sudo"
    cat > "$tmp/bin/install" <<STUB
#!/usr/bin/env bash
echo "install \$*" >> "$tmp/calls"
[ "$3" = 0 ] || exit 1
d=; args=()
while [ \$# -gt 0 ]; do case \$1 in -o|-g|-m) shift 2;; -d) d=1; shift;; *) args+=("\$1"); shift;; esac; done
if [ -n "\$d" ]; then mkdir -p "\${args[@]}"; else cp "\${args[0]}" "\${args[1]}"; fi
STUB
    printf '#!/usr/bin/env bash\n[ %s = 0 ] || exit 1\nexec /usr/bin/tee "$@"\n' "$4" > "$tmp/bin/tee"
    chmod +x "$tmp/bin/"*
    local i
    for i in $(seq "${6:-1}"); do
        PATH="$tmp/bin:$PATH" bash -c '
            echo_ok()   { echo "[ok] $1"; }
            echo_err()  { echo "[err] $1"; }
            echo_warn() { echo "[warn] $1"; }
            TODOS=(); todo() { TODOS+=("$1"); echo_err "$1"; }
            '"$(awk "/^enable_touchid_sudo\(\)/,/^\}/" "$BOOTSTRAP")"'
            enable_touchid_sudo "'"$tmp"'/sudo_local" "'"$tmp"'/pam_tid.so.2" \
                "'"$tmp"'/src/pam_reattach.so" "'"$tmp"'/root/lib/pam/pam_reattach.so"
            printf "TODOCOUNT:%d\n" "${#TODOS[@]}"
        ' 2>&1
    done
    echo "--- sudo_local:"; cat "$tmp/sudo_local" 2>/dev/null || echo "<absent>"
    [ -f "$tmp/sudo_local.bak" ] && { echo "--- backup:"; cat "$tmp/sudo_local.bak"; }
    [ -f "$tmp/calls" ] && { echo "--- calls:"; cat "$tmp/calls"; }
    rm -rf "$tmp"
}

echo "touch id: no Touch ID module (e.g. a VM without one)"
out=$(touchid_case none reattach 0 0 "")
check  "skips with a warning"   "No Touch ID PAM module"  "$out"
check  "writes nothing"         "<absent>"                "$out"
refute "installs nothing"       "--- calls:"              "$out"

echo "touch id: fresh machine"
out=$(touchid_case tid reattach 0 0 "")
check  "enables it"                 "Touch ID enabled for sudo"                "$out"
check  "loads the root-owned copy"  "root/lib/pam/pam_reattach.so ignore_ssh"  "$out"
refute "never the Homebrew path"    "src/pam_reattach.so ignore_ssh"           "$out"
check  "then pam_tid"               "auth       sufficient     pam_tid.so"     "$out"
check  "records no todo"            "TODOCOUNT:0"                              "$out"

echo "touch id: re-run is a no-op"
out=$(touchid_case tid reattach 0 0 "" 2)
check "second run reports it" "Touch ID for sudo already enabled" "$out"
n=$(printf '%s\n' "$out" | grep -c '^install .*-m 444')
check "copies the module once" "copies:1" "copies:$n"

echo "touch id: no pam_reattach installed"
out=$(touchid_case tid none 0 0 "")
check  "still enables Touch ID"    "Touch ID enabled for sudo" "$out"
refute "writes no reattach line"   "pam_reattach"              "$out"

echo "touch id: copying pam_reattach fails"
# The safety property: never reference a module that is not there.
out=$(touchid_case tid reattach 1 0 "")
check  "records a todo"                "Copy pam_reattach for Touch ID in tmux" "$out"
refute "does not reference the module" "pam_reattach.so ignore_ssh"             "$out"
check  "still enables plain Touch ID"  "auth       sufficient     pam_tid.so"   "$out"

echo "touch id: existing sudo_local"
out=$(touchid_case tid none 0 0 "auth       sufficient     pam_custom.so")
check "backs up the old file" "--- backup:
auth       sufficient     pam_custom.so" "$out"

echo "touch id: writing sudo_local fails"
out=$(touchid_case tid none 0 1 "")
check "records a todo" "Enable Touch ID for sudo: write" "$out"
check "counts it"      "TODOCOUNT:1"                     "$out"

# set_hostname: $1 = current name for all three keys, $2 = scutil --set exit
hostname_case() {
    local tmp; tmp=$(mktemp -d); mkdir "$tmp/state"
    local n; for n in ComputerName LocalHostName HostName; do
        [ -n "$1" ] && echo "$1" > "$tmp/state/$n"
    done
    cat > "$tmp/scutil" <<STUB
#!/usr/bin/env bash
case \$1 in
  --get) cat "$tmp/state/\$2" 2>/dev/null || { echo "\$2: not set"; exit 1; } ;;
  --set) echo "set \$2 \$3" >> "$tmp/calls"; [ "$2" = 0 ] || exit 1; echo "\$3" > "$tmp/state/\$2" ;;
esac
STUB
    printf '#!/usr/bin/env bash\nexec "$@"\n' > "$tmp/sudo"
    chmod +x "$tmp/scutil" "$tmp/sudo"
    PATH="$tmp:$PATH" bash -c '
        echo_ok()   { echo "[ok] $1"; }
        echo_err()  { echo "[err] $1"; }
        TODOS=(); todo() { TODOS+=("$1"); echo_err "$1"; }
        '"$(awk "/^set_hostname\(\)/,/^\}/" "$BOOTSTRAP")"'
        set_hostname mini
        printf "TODOCOUNT:%d\n" "${#TODOS[@]}"
    ' 2>&1
    [ -f "$tmp/calls" ] && cat "$tmp/calls"
    rm -rf "$tmp"
}

echo "hostname already mini"
out=$(hostname_case mini 0)
check  "reports it"   "Hostname already mini" "$out"
refute "sets nothing" "set "                  "$out"

echo "hostname from Setup Assistant (HostName unset)"
out=$(hostname_case "" 0)
check "sets ComputerName"  "set ComputerName mini"  "$out"
check "sets LocalHostName" "set LocalHostName mini" "$out"
check "sets HostName"      "set HostName mini"      "$out"
check "reports it"         "Hostname set to mini"   "$out"
check "records no todo"    "TODOCOUNT:0"            "$out"

echo "hostname change fails"
out=$(hostname_case "Levs-Virtual-Machine" 1)
check "records a todo per name" "TODOCOUNT:3" "$out"
check "with the command"        "Set the HostName: sudo scutil --set HostName mini" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
