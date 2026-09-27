# mini connect — attach to (or create) a persistent tmux session on the Mini.
#
# This is the core of the remote-first model: work lives in a long-running tmux
# session on the Mini, so attaching from anywhere drops you exactly where you
# left off, including a Claude Code conversation mid-task.
#
#   mini                   in ~/projects/<p>: session <p>, started in that folder;
#                          anywhere else: the '$MINI_SESSION' session
#   mini <name>            session <name> (anything that is not a mini command)
#   mini connect [name]    the same, spelled out; also for names that are commands
#
# A session named after a project starts in ~/projects/<name>. The path is the
# same on both machines (same username, and `mini repos` clones the same
# repos); where the folder is missing, tmux quietly starts in the home folder.

MINI_PROJECTS_DIR="${MINI_PROJECTS_DIR:-$HOME/projects}"

# The project folder $PWD is inside, if any: ~/projects/fresco/Sources → fresco.
_current_project() {
    local rel
    case "$PWD/" in
        "$MINI_PROJECTS_DIR"/?*) ;;
        *) return 1 ;;
    esac
    rel=${PWD#"$MINI_PROJECTS_DIR"/}
    printf '%s' "${rel%%/*}"
}

mini_connect() {
    local session dir=""
    local project
    if [ $# -gt 0 ]; then
        session=$(session_name "$1")
        project=$1
        debug "session '$session' from the name given"
    elif project=$(_current_project); then
        session=$(session_name "$project")
        debug "session '$session' from the project folder you are in ($PWD)"
    else
        session="$MINI_SESSION"
        debug "session '$session', the default: $PWD is not inside $MINI_PROJECTS_DIR"
    fi
    [ -n "${project:-}" ] && [ "$session" != "$project" ] \
        && debug "renamed '$project' to '$session': names keep to letters, digits, _ and -"

    # A project's session starts in its folder. Only when the name needed no
    # changing: the path crosses ssh unquoted, like the name.
    if [ -n "${project:-}" ] && [ "$session" = "$project" ] \
        && [ -d "$MINI_PROJECTS_DIR/$project" ]; then
        dir="$MINI_PROJECTS_DIR/$project"
        debug "if it has to be created, it starts in $dir"
    elif [ -n "${project:-}" ] && [ "$session" != "$project" ]; then
        debug "no start folder: the name had to change, and the path would cross ssh unquoted"
    elif [ -n "${project:-}" ]; then
        debug "no start folder: there is no $MINI_PROJECTS_DIR/$project here"
    fi

    # `new -A` attaches if the session exists and creates it otherwise, so one
    # command covers both "start my day" and "reattach". -c only applies when
    # it creates: an existing session keeps its own directory.
    local tmux_cmd=(tmux new -A -s "$session")
    [ -n "$dir" ] && tmux_cmd+=(-c "$dir")

    if is_server; then
        # Already on the Mini: attaching over ssh to ourselves would be absurd.
        debug "on the server: running tmux here"
        debug "\$ $(printf '%q ' "${tmux_cmd[@]}")"
        exec "${tmux_cmd[@]}"
    fi

    require_reachable
    if [ "$MINI_VERBOSE" = 1 ]; then
        if ssh -o BatchMode=yes "$MINI_HOST" tmux has-session -t "=$session" 2>/dev/null; then
            debug "'$session' exists on $MINI_HOST: attaching"
        else
            debug "'$session' does not exist on $MINI_HOST: creating it"
        fi
    fi

    if have mosh; then
        # mosh survives lid-close, IP changes and long suspends; ssh does not.
        debug "\$ mosh $MINI_HOST -- $(printf '%q ' "${tmux_cmd[@]}")"
        exec mosh "$MINI_HOST" -- "${tmux_cmd[@]}"
    else
        debug "mosh is not installed here; ssh drops the session on lid-close"
        debug "\$ ssh -t $MINI_HOST $(printf '%q ' "${tmux_cmd[@]}")"
        exec ssh -t "$MINI_HOST" "${tmux_cmd[@]}"
    fi
}
