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
    elif project=$(_current_project); then
        session=$(session_name "$project")
    else
        session="$MINI_SESSION"
    fi

    # A project's session starts in its folder. Only when the name needed no
    # changing: the path crosses ssh unquoted, like the name.
    if [ -n "${project:-}" ] && [ "$session" = "$project" ] \
        && [ -d "$MINI_PROJECTS_DIR/$project" ]; then
        dir="$MINI_PROJECTS_DIR/$project"
    fi

    # `new -A` attaches if the session exists and creates it otherwise, so one
    # command covers both "start my day" and "reattach". -c only applies when
    # it creates: an existing session keeps its own directory.
    local tmux_cmd=(tmux new -A -s "$session")
    [ -n "$dir" ] && tmux_cmd+=(-c "$dir")

    if is_server; then
        # Already on the Mini: attaching over ssh to ourselves would be absurd.
        exec "${tmux_cmd[@]}"
    fi

    require_reachable

    if have mosh; then
        # mosh survives lid-close, IP changes and long suspends; ssh does not.
        exec mosh "$MINI_HOST" -- "${tmux_cmd[@]}"
    else
        exec ssh -t "$MINI_HOST" "${tmux_cmd[@]}"
    fi
}
