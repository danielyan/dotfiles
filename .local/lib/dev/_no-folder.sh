#!/usr/bin/env bash
# The first window of a session `dev` started for a project the Mini has no
# folder for: says so in a box, then becomes the usual login shell, in home.
# Run on the Mini by tmux, never sourced, and not a subcommand.
#   _no-folder.sh <folder>

dir=${1:?usage: _no-folder.sh <folder>}
tilde='~'
host=$(hostname -s 2>/dev/null || hostname)
lines=(
    "⚠  NO SUCH FOLDER ON $host"
    ""
    "${dir/#"$HOME"/$tilde} does not exist here."
    "This session started in ~ instead."
    ""
    "Clone the listed repos:  dev repos sync"
)

if [ -t 1 ]; then warn=$'\033[33m'; off=$'\033[0m'; else warn=''; off=''; fi
# Widths count characters, not bytes: the ⚠ and the box are multibyte.
export LC_ALL=en_US.UTF-8
width=0
for line in "${lines[@]}"; do [ "${#line}" -gt "$width" ] && width=${#line}; done
printf -v bar '%*s' $((width + 4)) ''
bar=${bar// /═}
printf '%s╔%s╗\n' "$warn" "$bar"
for line in "${lines[@]}"; do printf '║  %s%*s  ║\n' "$line" $((width - ${#line})) ''; done
printf '╚%s╝%s\n\n' "$bar" "$off"
unset LC_ALL

exec "${SHELL:-/bin/bash}" -l
