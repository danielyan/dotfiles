# Completions only — the implementation is bash at ~/bin/mini.

set -l cmds connect doctor preflight pair ls run shell status help

complete -c mini -f
complete -c mini -n "not __fish_seen_subcommand_from $cmds" -a connect   -d "attach to a tmux session on the Mini"
complete -c mini -n "not __fish_seen_subcommand_from $cmds" -a ls        -d "list sessions without attaching"
complete -c mini -n "not __fish_seen_subcommand_from $cmds" -a run       -d "run one command remotely"
complete -c mini -n "not __fish_seen_subcommand_from $cmds" -a shell     -d "plain login shell, no tmux"
complete -c mini -n "not __fish_seen_subcommand_from $cmds" -a status    -d "quick health summary"
complete -c mini -n "not __fish_seen_subcommand_from $cmds" -a doctor    -d "check every link, with remedies"
complete -c mini -n "not __fish_seen_subcommand_from $cmds" -a preflight -d "prepare to work offline"
complete -c mini -n "not __fish_seen_subcommand_from $cmds" -a pair      -d "wire Syncthing to the Mini"
complete -c mini -n "not __fish_seen_subcommand_from $cmds" -a help      -d "usage"

# Live session names, but only when the Mini is actually reachable — otherwise
# every tab-press would block on a dead connection.
function __mini_sessions
    ssh -o ConnectTimeout=2 -o BatchMode=yes mini 'tmux ls -F "#{session_name}" 2>/dev/null' 2>/dev/null
end
complete -c mini -n "__fish_seen_subcommand_from connect" -a "(__mini_sessions)" -d session
