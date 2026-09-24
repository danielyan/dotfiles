#!/usr/bin/env bash
# Tests for mac-default-apps.
# Run: bash ~/.local/lib/yadm/mac-default-apps-tests.sh
#
# The script is sourced (its main() is guarded) and run against a stubbed
# utiluti backed by a state directory, so real defaults are never touched.
# The failure this guards against is the one duti caused: a set that exits 0
# but changes nothing. Every change must be read back.

set -uo pipefail
SUT="$HOME/bin/mac-default-apps"
pass=0; fail=0

check() {
    if [[ "$3" == *"$2"* ]]; then printf '  ✓ %s\n' "$1"; pass=$((pass+1))
    else printf '  ✗ %s\n      want: %s\n      got:  %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
refute() {
    if [[ "$3" != *"$2"* ]]; then printf '  ✓ %s\n' "$1"; pass=$((pass+1))
    else printf '  ✗ %s (unexpectedly found: %s)\n' "$1" "$2"; fail=$((fail+1)); fi
}

# utiluti KIND get ID --bundle-id | utiluti KIND set ID BUNDLE
# State lives in $STATE/<id>. With DECLINE set, `set` behaves like a dismissed
# dialog: exit 0, nothing stored — exactly how duti failed.
STUB='#!/usr/bin/env bash
kind=$1 op=$2 id=$3
case $op in
  get) [ -f "$STATE/$id" ] && cat "$STATE/$id"; exit 0 ;;
  set) echo "$kind $id $4" >> "$STATE/.calls"
       [ -n "${DECLINE:-}" ] || echo "$4" > "$STATE/$id"; exit 0 ;;
esac'

# $1 = "id=bundle ..." initial state, $2 = bindings lines, $3 = main args,
# $4 = "decline" to simulate dismissed dialogs, "missing" for no utiluti
run_case() {
    local tmp; tmp=$(mktemp -d); mkdir "$tmp/state"
    local path="$tmp/bin:$PATH" pair
    mkdir "$tmp/bin"
    if [ "${4:-}" = missing ]; then
        path="$tmp/bin:/usr/bin:/bin"
    else
        printf '%s\n' "$STUB" > "$tmp/bin/utiluti"; chmod +x "$tmp/bin/utiluti"
    fi
    for pair in $1; do echo "${pair#*=}" > "$tmp/state/${pair%%=*}"; done
    printf '%s\n' "$2" > "$tmp/bindings"

    PATH="$path" STATE="$tmp/state" DECLINE="$([ "${4:-}" = decline ] && echo 1)" bash -c "
        source '$SUT'
        bindings() { cat '$tmp/bindings'; }
        (main $3); echo \"EXIT:\$?\"
    " 2>&1
    [ -f "$tmp/state/.calls" ] && sed 's/^/called: /' "$tmp/state/.calls"
    rm -rf "$tmp"
}

B2='type com.aone.keka public.zip-archive
url com.brave.Browser https'

echo "already bound"
out=$(run_case "public.zip-archive=com.aone.keka https=com.brave.browser" "$B2" "")
refute "sets nothing"                         "called:"                        "$out"
check  "matches bundle ids case-insensitively" "Default applications bound."    "$out"
check  "exits 0"                               "EXIT:0"                         "$out"

echo "needs changes, dialogs accepted"
out=$(run_case "public.zip-archive=com.apple.archiveutility" "$B2" "")
check "sets the type"            "called: type public.zip-archive com.aone.keka" "$out"
check "sets the scheme"          "called: url https com.brave.Browser"           "$out"
check "reports the verified set" "[✓] public.zip-archive → com.aone.keka"        "$out"
check "exits 0"                  "EXIT:0"                                        "$out"

echo "dialog declined (set exits 0, changes nothing)"
out=$(run_case "public.zip-archive=com.apple.archiveutility" "$B2" "" decline)
check "catches it by reading back" "public.zip-archive still opens in com.apple.archiveutility" "$out"
check "reports an unset handler"   "https still opens in <none>"  "$out"
check "counts both"                "2 binding(s) failed"          "$out"
check "exits 1"                    "EXIT:1"                       "$out"

echo "--check"
out=$(run_case "public.zip-archive=com.apple.archiveutility https=com.brave.Browser" "$B2" "--check")
check  "lists the difference"   "public.zip-archive: com.apple.archiveutility → com.aone.keka" "$out"
refute "skips what matches"     "https:"            "$out"
refute "changes nothing"        "called:"           "$out"
check  "counts pending"         "1 binding(s) to change" "$out"
check  "exits 2"                "EXIT:2"            "$out"

out=$(run_case "public.zip-archive=com.aone.keka https=com.brave.Browser" "$B2" "--check")
check "clean check exits 0" "EXIT:0" "$out"

echo "utiluti missing"
out=$(run_case "" "$B2" "" missing)
check "says what to install" "utiluti not installed (brew install utiluti)" "$out"
check "exits 1"              "EXIT:1" "$out"

echo "sourcing is inert"
out=$(PATH="/usr/bin:/bin" bash -c "source '$SUT'; echo sourced" 2>&1)
check  "returns without running main" "sourced" "$out"
refute "does not demand utiluti"      "not installed" "$out"

echo "real binding list"
list=$(bash -c "source '$SUT'; bindings")
check "binds mkv via IINA's own UTI"  "type com.colliderli.iina io.iina.mkv"   "$list"
check "binds markdown to VS Code"     "type com.microsoft.VSCode net.daringfireball.markdown" "$list"
check "binds https to Brave"          "url com.brave.Browser https"            "$list"
refute "no unregistered matroska UTI" "org.matroska.mkv"                        "$list"
bad=$(printf '%s\n' "$list" | awk 'NF!=3 || ($1!="type" && $1!="url")')
check "every line is KIND BUNDLE ID"  "<ok>" "${bad:-<ok>}"
dups=$(printf '%s\n' "$list" | awk '{print $3}' | sort | uniq -d)
check "no identifier bound twice"     "<ok>" "${dups:-<ok>}"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
