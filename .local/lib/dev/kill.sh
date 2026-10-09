# dev kill — end a tmux session on the Mini, and whatever runs inside it.
#
#   dev kill <name>        kill the <name> session. A typo or partial name is
#                          not trusted with something this final: the session
#                          it means is named and, on a terminal, asked about
#                          first (magpei → Kill 'magpie'? [y/N]); a name
#                          several could mean opens the picker with just those
#   dev kill               pick a running session to kill: type to filter,
#                          arrows to move, enter to kill, esc to cancel

# _sessions, _pick, _interactive and _tty.
# shellcheck source=/dev/null
. "$DEV_LIB/connect.sh"

# End <session>. Told by what the Mini prints, like every remote check: its
# exit status says nothing.
_kill() { # <session>
    local target="=$1"
    debug "killing '$1' on $DEV_HOST"
    if is_server; then
        tmux kill-session -t "$target" 2>/dev/null
    else
        remote_ok "tmux kill-session -t $(printf '%q' "$target")"
    fi || die "could not kill '$1' on $DEV_HOST (dev ls shows what is running)"
    printf "%skilled '%s'%s\n" "$C_OK" "$1" "$C_OFF"
}

dev_kill() {
    [ $# -le 1 ] || die "dev kill takes one session name (dev kill alone lists them)"
    is_server || require_reachable

    local entries=() entry chosen
    while IFS= read -r entry; do
        [ -n "$entry" ] && entries+=("$entry")
    done < <(_sessions)
    debug "${#entries[@]} session(s) on $DEV_HOST"

    if [ $# -eq 0 ]; then
        _interactive || die "dev kill picks from a list, which needs a terminal (dev kill <name> kills by name)"
        if [ "${#entries[@]}" -eq 0 ]; then
            echo "no sessions on $DEV_HOST"
            return 0
        fi
        chosen=$(PICK_VERB=kill _pick "${entries[@]}") || return 1
        debug "picked '$chosen'"
        _kill "$chosen"
        return
    fi

    local session names=() matches=() name answer
    session=$(session_name "$1")
    for entry in ${entries[@]+"${entries[@]}"}; do names+=("${entry%%|*}"); done
    for name in ${names[@]+"${names[@]}"}; do
        [ "$name" = "$session" ] && { _kill "$session"; return; }
    done

    while IFS= read -r name; do matches+=("$name"); done \
        < <(_best_matches "$1" ${names[@]+"${names[@]}"})
    debug "running sessions close to '$1': ${matches[*]:-none}"
    if [ "${#matches[@]}" -eq 0 ]; then
        printf "%sno session '%s' on %s%s\n" "$C_WARN" "$session" "$DEV_HOST" "$C_OFF" >&2
        exit 1
    fi
    if [ "${#matches[@]}" -eq 1 ]; then
        printf "%sno session '%s' on %s, but there is '%s'%s\n" \
            "$C_WARN" "$session" "$DEV_HOST" "${matches[0]}" "$C_OFF" >&2
        if ! _interactive; then
            printf '  %s→ dev kill %s%s\n' "$C_DIM" "${matches[0]}" "$C_OFF" >&2
            exit 1
        fi
        printf "Kill '%s'? [y/N] " "${matches[0]}" >&2
        IFS= read -r answer < "$(_tty)" || answer=""
        case "$answer" in
            y|Y|yes|Yes) _kill "${matches[0]}"; return ;;
        esac
        exit 1
    fi

    if ! _interactive; then
        printf "%s'%s' could be any of: %s%s\n" "$C_WARN" "$1" "${matches[*]}" "$C_OFF" >&2
        printf '  %s→ dev kill %s%s\n' "$C_DIM" "${matches[0]}" "$C_OFF" >&2
        exit 1
    fi
    local close=()
    for entry in "${entries[@]}"; do
        for name in "${matches[@]}"; do
            [ "${entry%%|*}" = "$name" ] && close+=("$entry")
        done
    done
    printf "%s'%s' could be any of these:%s\n" "$C_WARN" "$1" "$C_OFF" >&2
    chosen=$(PICK_VERB=kill _pick "${close[@]}") || exit 1
    _kill "$chosen"
}
