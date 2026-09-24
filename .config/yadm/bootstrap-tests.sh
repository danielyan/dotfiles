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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
