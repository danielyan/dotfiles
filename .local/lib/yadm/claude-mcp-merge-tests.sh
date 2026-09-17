#!/usr/bin/env bash
# Tests for claude-mcp-merge.py.
# Run: bash ~/.local/lib/yadm/claude-mcp-merge-tests.sh

set -uo pipefail
MERGE="$HOME/.local/lib/yadm/claude-mcp-merge.py"
pass=0; fail=0

check() {
    if [[ "$3" == *"$2"* ]]; then printf '  ✓ %s\n' "$1"; pass=$((pass+1))
    else printf '  ✗ %s\n      want: %s\n      got:  %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "merging into an existing config"
cat > "$tmp/src.json" <<'JSON'
{"mcpServers": {"todoist": {"command": "node", "env": {"T": "secret"}}}}
JSON
cat > "$tmp/dst.json" <<'JSON'
{"numStartups": 42, "projects": {"/tmp/x": {"allowedTools": []}}, "mcpServers": {"old": {"command": "keep"}}}
JSON
out=$(python3 "$MERGE" "$tmp/src.json" "$tmp/dst.json")
check "reports what it merged" "merged 1 server" "$out"
check "adds the new server" '"todoist"' "$(cat "$tmp/dst.json")"
check "keeps servers only in the target" '"old"' "$(cat "$tmp/dst.json")"
check "preserves unrelated runtime state" '"numStartups": 42' "$(cat "$tmp/dst.json")"
check "keeps the target private" "600" "$(stat -f '%OLp' "$tmp/dst.json")"

echo "source wins on conflict"
cat > "$tmp/src2.json" <<'JSON'
{"mcpServers": {"old": {"command": "new-value"}}}
JSON
python3 "$MERGE" "$tmp/src2.json" "$tmp/dst.json" >/dev/null
check "overwrites the conflicting server" "new-value" "$(cat "$tmp/dst.json")"

echo "second run changes nothing"
out=$(python3 "$MERGE" "$tmp/src2.json" "$tmp/dst.json")
check "is idempotent" "unchanged" "$out"

echo "missing or empty input"
out=$(python3 "$MERGE" "$tmp/nope.json" "$tmp/dst.json")
check "no source is a no-op" "no source" "$out"
echo '{"mcpServers": {}}' > "$tmp/empty.json"
out=$(python3 "$MERGE" "$tmp/empty.json" "$tmp/dst.json")
check "empty source is a no-op" "no servers" "$out"

echo "missing target"
out=$(python3 "$MERGE" "$tmp/src.json" "$tmp/fresh.json")
check "creates the target" "merged 1 server" "$out"
check "writes the servers" '"todoist"' "$(cat "$tmp/fresh.json")"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
