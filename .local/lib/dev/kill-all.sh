# dev kill-all — end every tmux session on the Mini, after one confirmation.
#
#   dev kill-all           name the sessions and ask: Kill all 3? [y/N]
#   dev kill-all --yes     no question (-y too), for scripts. Without a
#                          terminal and without --yes nothing is killed
#
# Sessions end one by one (tmux kill-session), not with the tmux server: each
# is reported, and one that will not die does not spare the rest. Run from
# inside a session on the Mini, that session goes last; first, the command
# would die with it before reaching the others. `dev run tmux kill-server`
# remains the way to restart tmux itself.

# _end_session, and through kill.sh _sessions, _interactive and _tty.
# shellcheck source=/dev/null
. "$DEV_LIB/kill.sh"

# The session this command runs in, if it runs in one on the Mini. From any
# other machine, nothing on the Mini can be "this" session.
_own_session() {
    { is_server && [ -n "${TMUX:-}" ]; } || return 0
    tmux display-message -p '#S' 2>/dev/null
}

dev_kill-all() {
    local yes=0 arg
    for arg; do
        case "$arg" in
            -y|--yes) yes=1 ;;
            *) die "dev kill-all takes only --yes (dev kill <name> ends one session)" ;;
        esac
    done
    is_server || require_reachable

    local names=() entry own
    while IFS= read -r entry; do
        [ -n "$entry" ] && names+=("${entry%%|*}")
    done < <(_sessions)
    debug "${#names[@]} session(s) on $DEV_HOST"
    if [ "${#names[@]}" -eq 0 ]; then
        echo "no sessions on $DEV_HOST"
        return 0
    fi

    # This session last.
    own=$(_own_session)
    local order=() name
    for name in "${names[@]}"; do [ "$name" != "$own" ] && order+=("$name"); done
    [ "${#order[@]}" -lt "${#names[@]}" ] && order+=("$own")
    debug "kill order: ${order[*]}"

    if [ "$yes" -eq 0 ]; then
        local count="${#order[@]} sessions" all="all ${#order[@]}"
        [ "${#order[@]}" -eq 1 ] && { count="1 session"; all="it"; }
        printf '%s on %s: %s\n' "$count" "$DEV_HOST" "$(printf '%s\n' "${order[@]}" | paste -sd ',' - | sed 's/,/, /g')" >&2
        if [ -n "$own" ] && [ "${#order[@]}" -gt 1 ]; then
            printf "%s(this session, '%s', goes last)%s\n" "$C_DIM" "$own" "$C_OFF" >&2
        fi
        if ! _interactive; then
            printf '%snothing killed: confirming needs a terminal%s\n' "$C_WARN" "$C_OFF" >&2
            printf '  %s→ dev kill-all --yes%s\n' "$C_DIM" "$C_OFF" >&2
            exit 1
        fi
        local answer
        printf 'Kill %s? [y/N] ' "$all" >&2
        IFS= read -r answer < "$(_tty)" || answer=""
        case "$answer" in
            y|Y|yes|Yes) ;;
            *) exit 1 ;;
        esac
    fi

    local failed=()
    for name in "${order[@]}"; do
        _end_session "$name" || failed+=("$name")
    done
    if [ "${#failed[@]}" -gt 0 ]; then
        die "could not kill: ${failed[*]} (dev ls shows what is running)"
    fi
}
