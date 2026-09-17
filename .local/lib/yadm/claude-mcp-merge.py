#!/usr/bin/env python3
"""Merge decrypted MCP server definitions into ~/.claude.json.

~/.claude.json mixes secrets (mcpServers env tokens) with Claude Code's own
runtime state, so the whole file can't live in yadm. The server definitions are
kept separately in ~/.config/claude/mcp-servers.json, encrypted via
`yadm encrypt`, and merged back in by bootstrap.

Usage: claude-mcp-merge.py <source.json> <target.json>

Only the mcpServers key is touched; every other key in the target survives. A
server present in both wins from the source. Missing source is a no-op, so
bootstrap can call this unconditionally.
"""
import json
import os
import sys
import tempfile


def merge(source_path, target_path):
    if not os.path.exists(source_path):
        return "no source"

    with open(source_path) as fh:
        servers = json.load(fh).get("mcpServers", {})
    if not servers:
        return "no servers"

    target = {}
    if os.path.exists(target_path):
        with open(target_path) as fh:
            target = json.load(fh)

    merged = dict(target.get("mcpServers", {}))
    merged.update(servers)
    if merged == target.get("mcpServers"):
        return "unchanged"
    target["mcpServers"] = merged

    # Write via a temp file in the same dir so a crash can't truncate the
    # original: Claude Code may be running while bootstrap does this.
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(target_path) or ".")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(target, fh, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, target_path)
    except Exception:
        os.unlink(tmp)
        raise
    return "merged %d server(s)" % len(servers)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    print(merge(sys.argv[1], sys.argv[2]))
