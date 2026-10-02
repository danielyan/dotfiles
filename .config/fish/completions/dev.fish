# Completions only — the implementation is bash at ~/bin/dev.

set -l cmds connect doctor preflight land pair ls run shell status repos help

complete -c dev -f
complete -c dev -n "not __fish_seen_subcommand_from $cmds" -a connect   -d "attach to a session, by name"
complete -c dev -n "not __fish_seen_subcommand_from $cmds" -a ls        -d "list sessions without attaching"
complete -c dev -n "not __fish_seen_subcommand_from $cmds" -a run       -d "run one command remotely"
complete -c dev -n "not __fish_seen_subcommand_from $cmds" -a shell     -d "plain login shell, no tmux"
complete -c dev -n "not __fish_seen_subcommand_from $cmds" -a status    -d "quick health summary"
complete -c dev -n "not __fish_seen_subcommand_from $cmds" -a doctor    -d "check every link, with remedies"
complete -c dev -n "not __fish_seen_subcommand_from $cmds" -a preflight -d "prepare to work offline"
complete -c dev -n "not __fish_seen_subcommand_from $cmds" -a pair      -d "wire Syncthing to the Mini"
complete -c dev -n "not __fish_seen_subcommand_from $cmds" -a land      -d "reconcile after working offline"
complete -c dev -n "not __fish_seen_subcommand_from $cmds" -a repos     -d "the repos ~/projects should hold"
complete -c dev -n "not __fish_seen_subcommand_from $cmds" -a help      -d "usage"

# Live session names, but only when the Mini is actually reachable — otherwise
# every tab-press would block on a dead connection.
function __dev_sessions
    ssh -o ConnectTimeout=2 -o BatchMode=yes mini 'tmux ls -F "#{session_name}" 2>/dev/null' 2>/dev/null
end

# Project folders: `dev <project>` starts that project's session in it.
function __dev_projects
    for d in ~/projects/*/
        basename $d
    end
end

# `dev <name>` attaches to a session, so names complete where commands do.
complete -c dev -n "not __fish_seen_subcommand_from $cmds" -a "(__dev_sessions)" -d session
complete -c dev -n "not __fish_seen_subcommand_from $cmds" -a "(__dev_projects)" -d project
complete -c dev -n "__fish_seen_subcommand_from connect" -a "(__dev_sessions)" -d session
complete -c dev -n "__fish_seen_subcommand_from connect" -a "(__dev_projects)" -d project

# dev repos <sub>
set -l repos_subs list add remove sync status help
complete -c dev -n "__fish_seen_subcommand_from repos; and not __fish_seen_subcommand_from $repos_subs" -a list   -d "every entry, and whether it is cloned"
complete -c dev -n "__fish_seen_subcommand_from repos; and not __fish_seen_subcommand_from $repos_subs" -a add    -d "add repos by URL or existing clone"
complete -c dev -n "__fish_seen_subcommand_from repos; and not __fish_seen_subcommand_from $repos_subs" -a remove -d "drop entries; clones untouched"
complete -c dev -n "__fish_seen_subcommand_from repos; and not __fish_seen_subcommand_from $repos_subs" -a sync   -d "clone whatever is missing"
complete -c dev -n "__fish_seen_subcommand_from repos; and not __fish_seen_subcommand_from $repos_subs" -a status -d "like list; exit 2 if anything is missing"
complete -c dev -n "__fish_seen_subcommand_from repos; and not __fish_seen_subcommand_from $repos_subs" -a help   -d "usage"
complete -c dev -n "__fish_seen_subcommand_from repos; and __fish_seen_subcommand_from add" -a "(__dev_projects)" -d "clone here"
complete -c dev -n "__fish_seen_subcommand_from repos; and __fish_seen_subcommand_from remove" \
    -a "(awk '!/^[[:space:]]*(#|\$)/ { print \$1 }' ~/.config/dev/repos 2>/dev/null)" -d listed
