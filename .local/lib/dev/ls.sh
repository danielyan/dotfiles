# dev ls — what is running on the Mini, without attaching to it.

dev_ls() {
    if is_server; then
        [ "$DEV_VERBOSE" = 1 ] && debug "tmux says: $(command tmux ls 2>&1 | head -1)"
        tmux ls 2>/dev/null || { echo "no sessions"; return 0; }
        return 0
    fi

    require_reachable
    local out
    out=$(ssh -o BatchMode=yes "$DEV_HOST" 'tmux ls 2>/dev/null')
    if [ -z "$out" ]; then
        # "no sessions" covers both a server with none and no server at all;
        # tmux's own words say which.
        [ "$DEV_VERBOSE" = 1 ] \
            && debug "tmux on $DEV_HOST says: $(command ssh -o BatchMode=yes "$DEV_HOST" 'tmux ls 2>&1' | head -1)"
        echo "no sessions on $DEV_HOST"
        printf '  %s→ dev starts main%s\n' "$C_DIM" "$C_OFF"
        return 0
    fi
    printf '%s\n' "$out"
}
