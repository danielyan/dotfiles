# mini — attach to the persistent tmux session on the Mac Mini.
#
# This is the core of the remote-first model: work lives in a long-running tmux
# session on the always-on Mini, so attaching from anywhere drops you exactly
# where you left off — including a Claude Code conversation mid-task.
#
# Uses mosh when available so the link survives lid-close and network changes.
# See vault: projects/project-machine-continuity.md
#
#   mini            attach to (or create) the 'main' session
#   mini magpie     attach to (or create) a session named 'magpie'
#   mini -l         list sessions running on the Mini
#   mini -s         run a plain shell, no tmux

function mini --description "Attach to the persistent tmux session on the Mini"
    set -l host mini
    set -l session main

    argparse l/list s/shell h/help -- $argv
    or return 1

    if set -q _flag_help
        echo "usage: mini [session] | mini -l | mini -s"
        return 0
    end

    test (count $argv) -gt 0; and set session $argv[1]

    if not command -q ssh
        echo "mini: ssh not found" >&2
        return 1
    end

    # Fail fast with a useful message rather than a 30s TCP timeout.
    if not ssh -o ConnectTimeout=5 -o BatchMode=yes $host true 2>/dev/null
        echo "mini: cannot reach '$host' — is Tailscale up and the Mini awake?" >&2
        return 1
    end

    if set -q _flag_list
        ssh $host tmux list-sessions
        return $status
    end

    if set -q _flag_shell
        ssh -t $host
        return $status
    end

    # `new -A` attaches if the session exists, creates it otherwise.
    if command -q mosh
        mosh $host -- tmux new -A -s $session
    else
        ssh -t $host tmux new -A -s $session
    end
end
