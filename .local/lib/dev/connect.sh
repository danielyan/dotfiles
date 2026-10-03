# dev connect — get into a persistent tmux session on the Mini.
#
# This is the core of the remote-first model: work lives in a long-running tmux
# session on the Mini, so attaching from anywhere drops you exactly where you
# left off, including a Claude Code conversation mid-task.
#
#   dev                    in ~/projects/<p>/..., the <p> session, started in
#                          ~/projects/<p> if need be; if the Mini has no such
#                          folder, started in home, saying so in a box there.
#                          Elsewhere, the session named after the folder if one
#                          is running. Otherwise main, started if need be
#   dev <name>             the <name> session. Typos and partial names find the
#                          running session meant (magpei, mag → magpie); a name
#                          several could mean opens the picker with just those.
#                          A missing session is not started silently: dev says
#                          so and, on a terminal, offers to (fresko → fresco, if
#                          ~/projects/fresco exists). main always just starts
#   dev connect            pick a running session: type to filter, arrows to
#                          move, enter to attach, esc to cancel
#
# Only main, a project's own folder, and a yes to the offer start a session. A
# session started for a project begins in ~/projects/<name>; the path is the
# same on both machines (same username, and `dev repos` clones the same repos),
# but whether the folder is there is asked of the Mini.

DEV_PROJECTS_DIR="${DEV_PROJECTS_DIR:-$HOME/projects}"

# The project folder $PWD is inside, if any: ~/projects/fresco/Sources → fresco.
_current_project() {
    local rel
    case "$PWD/" in
        "$DEV_PROJECTS_DIR"/?*) ;;
        *) return 1 ;;
    esac
    rel=${PWD#"$DEV_PROJECTS_DIR"/}
    printf '%s' "${rel%%/*}"
}

# The name `dev` looks for here: the project, else this folder's own name. Home
# and the projects folder itself name nothing: they mean main.
_here_name() {
    _current_project && return 0
    case "$PWD" in
        "$HOME"|"$DEV_PROJECTS_DIR"|/) return 1 ;;
    esac
    printf '%s' "${PWD##*/}"
}

# Is <dir> a folder on the Mini? Asked of the Mini itself: a project can be
# cloned on one machine and not the other.
_dir_on_host() { # <dir>
    if is_server; then
        [ -d "$1" ]
    else
        remote_ok "test -d $(printf '%q' "$1")"
    fi
}

# Where a session would start: a project's folder, when the name needed no
# changing (the path crosses ssh unquoted, like the name) and the folder exists
# on the Mini.
_start_dir() { # <name as given> <session>
    [ "$1" = "$2" ] && _dir_on_host "$DEV_PROJECTS_DIR/$1" && printf '%s' "$DEV_PROJECTS_DIR/$1"
}

# The terminal to ask on. DEV_TTY points it at a file of keystrokes in tests.
_tty() { printf '%s' "${DEV_TTY:-/dev/tty}"; }
_interactive() { [ -n "${DEV_TTY:-}" ] || { [ -t 0 ] && [ -t 2 ]; }; }

# Running sessions, one `name|attached-clients` per line.
_sessions() {
    local list="tmux ls -F '#{session_name}|#{session_attached}' 2>/dev/null"
    if is_server; then
        bash -c "$list"
    else
        remote_bash "$list"
    fi
}

# Attach to <session>, starting it (in [dir], its first window running
# [command...] rather than a plain shell) if it is not running: `new -A`
# attaches when the session exists, and -c and the command only apply when it
# creates. Like the name, every word crosses ssh bare: keep them plain.
_attach() { # <session> [dir] [command...]
    local tmux_cmd=(tmux new -A -s "$1")
    [ -n "${2:-}" ] && tmux_cmd+=(-c "$2")
    [ $# -gt 2 ] && tmux_cmd+=("${@:3}")

    if is_server; then
        # Already on the Mini: attaching over ssh to ourselves would be absurd.
        debug "on the server: running tmux here"
        debug "\$ $(printf '%q ' "${tmux_cmd[@]}")"
        exec "${tmux_cmd[@]}"
    fi

    require_reachable
    if have mosh; then
        # mosh survives lid-close, IP changes and long suspends; ssh does not.
        # It also puts "[mosh] " in front of the tab title tmux sets, unless
        # told not to.
        export MOSH_TITLE_NOPREFIX=1
        debug "\$ mosh $DEV_HOST -- $(printf '%q ' "${tmux_cmd[@]}")"
        exec mosh "$DEV_HOST" -- "${tmux_cmd[@]}"
    else
        debug "mosh is not installed here; ssh drops the session on lid-close"
        debug "\$ ssh -t $DEV_HOST $(printf '%q ' "${tmux_cmd[@]}")"
        exec ssh -t "$DEV_HOST" "${tmux_cmd[@]}"
    fi
}

# `dev`: in a project, its session, started in its folder if need be;
# elsewhere this folder's session if it is running; else main.
_connect_here() {
    local name session project dir
    is_server || require_reachable
    if project=$(_current_project); then
        session=$(session_name "$project")
        if _session_exists "$session"; then
            debug "'$session' exists on $DEV_HOST, the project $PWD is in: attaching"
            _attach "$session"
        fi
        dir="$DEV_PROJECTS_DIR/$project"
        # The name was cleaned (my.proj → my_proj), but the path still
        # crosses ssh as one bare word: only plain characters make it.
        if ! [[ "$project" =~ ^[A-Za-z0-9._-]+$ ]]; then
            debug "'$project' has characters a path cannot cross ssh with: starting '$session' in home"
            _attach "$session"
        fi
        if _dir_on_host "$dir"; then
            debug "starting '$session' in $dir"
            _attach "$session" "$dir"
        fi
        # Started anyway, in home, and the session itself says why: the box
        # is drawn on the Mini, where it stays on screen, not here, where
        # tmux would cover it at once.
        debug "$dir is not on $DEV_HOST: starting '$session' in home, with a notice"
        _attach "$session" "$HOME" "$DEV_LIB/_no-folder.sh" "$dir"
    fi
    if name=$(_here_name); then
        session=$(session_name "$name")
        if _session_exists "$session"; then
            debug "'$session' exists on $DEV_HOST, named after $PWD: attaching"
            _attach "$session"
        fi
        debug "no '$session' session on $DEV_HOST for $PWD: '$DEV_SESSION' instead"
    else
        debug "$PWD names no session: '$DEV_SESSION', the default"
    fi
    _attach "$DEV_SESSION"
}

# The project folders, by name: what a session could be started for.
_projects() {
    local d
    for d in "$DEV_PROJECTS_DIR"/*/; do
        [ -d "$d" ] && { d=${d%/}; printf '%s\n' "${d##*/}"; }
    done
}

# `dev <name>`: that session, or the running one it most plausibly means;
# failing that, say it is missing and offer to start it.
_connect_named() {
    local session answer dir entries=() names=() matches=() entry name
    is_server || require_reachable
    session=$(session_name "$1")
    [ "$session" != "$1" ] \
        && debug "renamed '$1' to '$session': names keep to letters, digits, _ and -"
    if [ "$(printf '%s' "$session" | tr '[:upper:]' '[:lower:]')" = "$DEV_SESSION" ]; then
        session=$DEV_SESSION
        debug "'$session' is the default session: attaching, starting it if need be"
        _attach "$session"
    fi

    while IFS= read -r entry; do
        [ -n "$entry" ] && { entries+=("$entry"); names+=("${entry%%|*}"); }
    done < <(_sessions)
    for name in ${names[@]+"${names[@]}"}; do
        [ "$name" = "$session" ] && { debug "'$session' exists on $DEV_HOST: attaching"; _attach "$session"; }
    done

    while IFS= read -r name; do matches+=("$name"); done \
        < <(_best_matches "$1" ${names[@]+"${names[@]}"})
    debug "running sessions close to '$1': ${matches[*]:-none}"
    if [ "${#matches[@]}" -eq 1 ]; then
        printf '%s%s → %s%s\n' "$C_DIM" "$1" "${matches[0]}" "$C_OFF" >&2
        _attach "${matches[0]}"
    elif [ "${#matches[@]}" -gt 1 ]; then
        if _interactive; then
            local close=()
            for entry in "${entries[@]}"; do
                for name in "${matches[@]}"; do
                    [ "${entry%%|*}" = "$name" ] && close+=("$entry")
                done
            done
            printf "%s'%s' could be any of these:%s\n" "$C_WARN" "$1" "$C_OFF" >&2
            name=$(_pick "${close[@]}") || exit 1
            _attach "$name"
        fi
        printf "%s'%s' could be any of: %s%s\n" "$C_WARN" "$1" "${matches[*]}" "$C_OFF" >&2
        printf '  %s→ dev %s%s\n' "$C_DIM" "${matches[0]}" "$C_OFF" >&2
        exit 1
    fi

    printf "%sno session '%s' on %s%s\n" "$C_WARN" "$session" "$DEV_HOST" "$C_OFF" >&2
    # Not running, so maybe a project that could be: the one folder it means.
    local folders=() projects=() project=""
    while IFS= read -r name; do folders+=("$name"); done < <(_projects)
    while IFS= read -r name; do projects+=("$name"); done \
        < <(_best_matches "$1" ${folders[@]+"${folders[@]}"})
    if [ "${#projects[@]}" -eq 1 ] && [ "${projects[0]}" != "$1" ]; then
        project=${projects[0]}
        debug "'$1' is close to the project folder '$project'"
        set -- "$project"
        session=$(session_name "$project")
    fi
    dir=$(_start_dir "$1" "$session")
    if ! _interactive; then
        printf '  %s→ run dev %s in a terminal to start it%s\n' "$C_DIM" "$1" "$C_OFF" >&2
        exit 1
    fi
    if [ -n "$project" ]; then
        printf "Start '%s'%s? [y/N] " "$session" "${dir:+ in $dir}" >&2
    else
        printf 'Start it%s? [y/N] ' "${dir:+ in $dir}" >&2
    fi
    IFS= read -r answer < "$(_tty)" || answer=""
    case "$answer" in
        y|Y|yes|Yes) debug "starting '$session'${dir:+ in $dir}"; _attach "$session" "$dir" ;;
    esac
    exit 1
}

# The entries whose session name contains <filter>, then those that have its
# letters in order with gaps between (mgp finds magpie), ignoring case.
_filter_sessions() { # <filter> <name|attached>...
    local filter=$1 entry restore spread="*" i
    shift
    # Each letter escaped, so a typed * or [ is only itself.
    for ((i = 0; i < ${#filter}; i++)); do spread+="\\${filter:i:1}*"; done
    restore=$(shopt -p nocasematch)
    shopt -s nocasematch
    for entry in "$@"; do
        [[ "${entry%%|*}" == *"$filter"* ]] && printf '%s\n' "$entry"
    done
    for entry in "$@"; do
        [[ "${entry%%|*}" == *"$filter"* ]] && continue
        # shellcheck disable=SC2053 # the pattern is the point
        [[ "${entry%%|*}" == $spread ]] && printf '%s\n' "$entry"
    done
    eval "$restore"
}

# An interactive list of <name|attached> entries, drawn on stderr and read from
# the terminal: type to filter, ↑/↓ (or ctrl-p/ctrl-n) to move, enter to pick,
# esc or ctrl-c to cancel. Prints the chosen name; returns 1 if cancelled.
_pick() {
    local entries=("$@") shown=() filter="" sel=0 drawn=0 key rest chosen=""
    local rows=${DEV_PICK_ROWS:-10} tty saved
    tty=$(_tty)
    exec 6< "$tty" || return 1
    saved=$(stty -g < "$tty" 2>/dev/null)
    stty -echo < "$tty" 2>/dev/null
    printf '\033[?25l' >&2
    _pick_restore() {
        [ -n "$saved" ] && stty "$saved" < "$tty" 2>/dev/null
        # Up over what was drawn, and clear it: the list leaves no trace.
        [ "$drawn" -gt 0 ] && printf '\r\033[%dA' "$drawn" >&2
        printf '\r\033[J\033[?25h' >&2
        exec 6<&-
    }
    trap '_pick_restore; exit 130' INT TERM

    while :; do
        shown=()
        while IFS= read -r rest; do shown+=("$rest"); done \
            < <(_filter_sessions "$filter" "${entries[@]}")
        [ "$sel" -ge "${#shown[@]}" ] && sel=$(( ${#shown[@]} - 1 ))
        [ "$sel" -lt 0 ] && sel=0
        _pick_draw

        IFS= read -rsn1 key <&6 || break
        case "$key" in
            $'\e')
                # An arrow is esc plus two more bytes, all at once; esc alone
                # is cancel. bash 3.2 only takes whole seconds for -t.
                rest=""
                IFS= read -rsn2 -t 1 rest <&6
                case "$rest" in
                    '[A'|OA) sel=$((sel - 1)) ;;
                    '[B'|OB) sel=$((sel + 1)) ;;
                    '') break ;;
                esac ;;
            ''|$'\r')
                [ "${#shown[@]}" -gt 0 ] && { chosen=${shown[$sel]%%|*}; break; } ;;
            $'\x10') sel=$((sel - 1)) ;;
            $'\x0e') sel=$((sel + 1)) ;;
            $'\x7f'|$'\b') filter=${filter%?}; sel=0 ;;
            $'\x15') filter=""; sel=0 ;;
            *) [[ "$key" == [[:print:]] ]] && { filter+=$key; sel=0; } ;;
        esac
    done

    _pick_restore
    trap - INT TERM
    [ -n "$chosen" ] || return 1
    printf '%s\n' "$chosen"
}

# One frame of the list: the filter line, the visible matches with the
# selection marked, and a hint. Redrawn in place over the previous frame.
_pick_draw() {
    local out="" line i first=0 last name attached
    [ "$sel" -ge "$rows" ] && first=$((sel - rows + 1))
    last=$((first + rows))
    [ "$last" -gt "${#shown[@]}" ] && last=${#shown[@]}

    [ "$drawn" -gt 0 ] && printf -v out '\r\033[%dA' "$drawn"
    out+=$'\r\033[J'
    printf -v line '%ssession:%s %s%s▏%s\n' "$C_BOLD" "$C_OFF" "$filter" "$C_DIM" "$C_OFF"
    out+=$line; drawn=1
    if [ "${#shown[@]}" -eq 0 ]; then
        printf -v line '  %sno session matches%s\n' "$C_DIM" "$C_OFF"
        out+=$line; drawn=$((drawn + 1))
    fi
    for ((i = first; i < last; i++)); do
        name=${shown[$i]%%|*}; attached=${shown[$i]##*|}
        [ "${attached:-0}" -gt 0 ] 2>/dev/null && attached=" ${C_DIM}(attached)${C_OFF}" || attached=""
        if [ "$i" -eq "$sel" ]; then
            printf -v line '%s❯ %s%s%s\n' "$C_OK" "$name" "$C_OFF" "$attached"
        else
            printf -v line '  %s%s\n' "$name" "$attached"
        fi
        out+=$line; drawn=$((drawn + 1))
    done
    [ "$last" -lt "${#shown[@]}" ] && {
        printf -v line '  %s… %d more%s\n' "$C_DIM" $(( ${#shown[@]} - last )) "$C_OFF"
        out+=$line; drawn=$((drawn + 1)); }
    printf -v line '%s↑↓ move · enter attach · esc cancel%s\n' "$C_DIM" "$C_OFF"
    out+=$line; drawn=$((drawn + 1))
    printf '%s' "$out" >&2
}

# `dev connect`: pick from the running sessions.
dev_connect() {
    [ $# -eq 0 ] || die "dev connect takes no name: it lists the sessions to pick from (dev <name> attaches by name)"
    _interactive || die "dev connect picks from a list, which needs a terminal (dev ls lists the sessions)"
    is_server || require_reachable

    local entries=() entry chosen
    while IFS= read -r entry; do
        [ -n "$entry" ] && entries+=("$entry")
    done < <(_sessions)
    debug "${#entries[@]} session(s) on $DEV_HOST"
    if [ "${#entries[@]}" -eq 0 ]; then
        echo "no sessions on $DEV_HOST"
        printf '  %s→ dev starts main%s\n' "$C_DIM" "$C_OFF"
        return 0
    fi

    chosen=$(_pick "${entries[@]}") || return 1
    debug "picked '$chosen'"
    _attach "$chosen"
}
