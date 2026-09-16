# mini land — reconcile after working offline. The counterpart to preflight.
#
# Most of the system heals itself on reconnect: Syncthing catches ~/.claude up,
# atuin syncs on the next command, iCloud handles the vault. Two things do not.
#
# Git commits made on this machine are invisible to the Mini until they go
# through the remote, and the Mini's tmux sessions are older than those commits —
# their shells sit in working trees at the old state, and anything long-running
# in them is executing pre-trip code. Attaching feels like continuity and is not.

_confirm() {
    local reply
    # Prompt on the tty so this still works when output is piped; fall back to
    # stdin when there is no tty, which is also what makes it testable.
    if [ -r /dev/tty ] && [ -t 1 ]; then
        printf '\n%s [y/N] ' "$1" > /dev/tty
        read -r reply < /dev/tty
    else
        printf '\n%s [y/N] ' "$1"
        read -r reply || return 1
    fi
    [ "$reply" = "y" ] || [ "$reply" = "Y" ]
}

mini_land() {
    is_server && die "run this from the Air; the Mini is what gets caught up"
    require_reachable

    local projects_dir="${PROJECTS_DIR:-$HOME/projects}"
    local -a to_push=() dirty=() names=()
    local dir name ahead

    section "Surveying local repos"
    for dir in "$projects_dir"/*/; do
        [ -d "$dir/.git" ] || continue
        name=$(basename "$dir")
        names+=("$name")

        if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
            dirty+=("$name")
        fi
        git -C "$dir" remote get-url origin >/dev/null 2>&1 || continue
        ahead=$(git -C "$dir" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
        [ "${ahead:-0}" -gt 0 ] && to_push+=("$name:$ahead")
    done

    # Dotfiles ride the same rails.
    local yadm_ahead=0
    if have yadm; then
        yadm_ahead=$(yadm rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
        [ "${yadm_ahead:-0}" -gt 0 ] && to_push+=("dotfiles(yadm):$yadm_ahead")
    fi

    if [ "${#dirty[@]}" -gt 0 ]; then
        for name in "${dirty[@]}"; do
            maybe "$name — uncommitted changes, not pushed" "commit or stash, then re-run"
        done
    fi

    if [ "${#to_push[@]}" -eq 0 ]; then
        ok "nothing to push — the Mini is not missing any commits"
    else
        section "Will push"
        for name in "${to_push[@]}"; do
            printf '  %s (%s commit(s))\n' "${name%:*}" "${name##*:}"
        done

        if _confirm "Push these?"; then
            for name in "${to_push[@]}"; do
                name="${name%:*}"
                if [ "$name" = "dotfiles(yadm)" ]; then
                    yadm push --quiet && ok "dotfiles pushed" || no "dotfiles push failed"
                else
                    git -C "$projects_dir/$name" push --quiet \
                        && ok "$name pushed" || no "$name push failed"
                fi
            done
        else
            maybe "skipped pushing — the Mini will stay behind"
        fi
    fi

    section "Catching up the Mini"
    # One ssh round trip rather than one per repo.
    local pulled
    pulled=$(ssh -o BatchMode=yes "$MINI_HOST" -- bash -lc "'
        cd \"\$HOME\" || exit 1
        command -v yadm >/dev/null && yadm pull --ff-only --quiet 2>/dev/null \
            && echo \"PULLED:dotfiles\"
        for d in \"\$HOME\"/projects/*/; do
            [ -d \"\$d/.git\" ] || continue
            n=\$(basename \"\$d\")
            git -C \"\$d\" remote get-url origin >/dev/null 2>&1 || continue
            if [ -n \"\$(git -C \"\$d\" status --porcelain 2>/dev/null)\" ]; then
                echo \"DIRTY:\$n\"; continue
            fi
            before=\$(git -C \"\$d\" rev-parse HEAD 2>/dev/null)
            git -C \"\$d\" pull --ff-only --quiet 2>/dev/null || { echo \"FAILED:\$n\"; continue; }
            after=\$(git -C \"\$d\" rev-parse HEAD 2>/dev/null)
            [ \"\$before\" != \"\$after\" ] && echo \"PULLED:\$n\"
        done
    '" 2>/dev/null)

    local changed=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in
            PULLED:*) ok "${line#PULLED:} updated on $MINI_HOST"; changed=$((changed+1)) ;;
            DIRTY:*)  maybe "${line#DIRTY:} — dirty on $MINI_HOST, not pulled" ;;
            FAILED:*) no "${line#FAILED:} — pull failed on $MINI_HOST" ;;
        esac
    done <<< "$pulled"
    [ "$changed" -eq 0 ] && ok "$MINI_HOST was already up to date"

    section "Claude state"
    if have syncthing && curl -sf -m 3 -o /dev/null "$SYNCTHING_API/rest/noauth/health"; then
        local conflicts
        conflicts=$(find "$HOME/.claude" -name '*sync-conflict*' 2>/dev/null | wc -l | tr -d ' ')
        if [ "${conflicts:-0}" -gt 0 ]; then
            maybe "$conflicts conflict file(s) — Claude ran on both machines" \
                  "keep the larger, delete the rest"
            find "$HOME/.claude" -name '*sync-conflict*' 2>/dev/null | sed 's|^|      |'
        else
            ok "no sync conflicts"
        fi
    else
        maybe "syncthing not running — ~/.claude has not caught up" "brew services start syncthing"
    fi

    # The part that is easy to miss: sessions predate the commits just pulled.
    if [ "$changed" -gt 0 ]; then
        section "Stale sessions on $MINI_HOST"
        local sessions
        sessions=$(ssh -o BatchMode=yes "$MINI_HOST" \
            'tmux ls -F "#{session_name} (#{session_windows} windows, started #{t:session_created})" 2>/dev/null')
        if [ -n "$sessions" ]; then
            printf '%s\n' "$sessions" | sed 's|^|      |'
            maybe "these predate the commits just pulled" \
                  "restart anything long-running in them — it is still executing old code"
        else
            ok "no sessions running"
        fi
    fi

    section "Done"
    printf '  mini            attach and carry on\n'
}
