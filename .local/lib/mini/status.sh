# mini status — the fast answer to "is everything fine?".
#
# `mini doctor` is thorough and slow because it checks every link and tells you
# how to fix each one. This is the one-screen version for daily use.

mini_status() {
    local problems=0
    # Wrap the failure helper so `status` can be used in a script.
    _bad() { no "$@"; problems=$((problems+1)); }
    local role="workstation"
    is_server && role="always-on server"
    printf '%s%s%s  (%s)\n' "$C_BOLD" "$(scutil --get LocalHostName 2>/dev/null || hostname)" "$C_OFF" "$role"

    if is_server; then
        local n
        n=$(tmux ls 2>/dev/null | wc -l | tr -d ' ')
        [ "${n:-0}" -gt 0 ] && ok "$n tmux session(s)" || maybe "no tmux sessions"
    else
        if reachable; then
            local n
            n=$(ssh -o BatchMode=yes "$MINI_HOST" 'tmux ls 2>/dev/null | wc -l' 2>/dev/null | tr -d ' ')
            ok "$MINI_HOST reachable, ${n:-0} session(s)"
        else
            _bad "$MINI_HOST unreachable" "mini doctor"
        fi
    fi

    if have syncthing && curl -sf -m 3 -o /dev/null "$SYNCTHING_API/rest/noauth/health"; then
        local conflicts
        conflicts=$(find "$HOME/.claude" -name '*sync-conflict*' 2>/dev/null | wc -l | tr -d ' ')
        [ "${conflicts:-0}" -eq 0 ] && ok "syncthing running, no conflicts" \
            || maybe "syncthing running, $conflicts conflict file(s)" "mini doctor"
    else
        _bad "syncthing not running" "brew services start syncthing"
    fi

    if have yadm; then
        local dirty ahead behind
        dirty=$(yadm status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        ahead=$(yadm rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
        behind=$(yadm rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
        if [ "${dirty:-0}" -eq 0 ] && [ "$ahead" -eq 0 ] && [ "$behind" -eq 0 ]; then
            ok "dotfiles clean and in sync"
        else
            maybe "dotfiles: ${dirty} dirty, ${ahead} ahead, ${behind} behind" "yadm status"
        fi
    fi

    return $(( problems > 0 ? 1 : 0 ))
}
