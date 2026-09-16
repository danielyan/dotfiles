# mini run — run one command on the Mini and come straight back.
#
# For things that do not deserve a session: `mini run brew upgrade`,
# `mini run git -C projects/magpie status`.

mini_run() {
    [ $# -gt 0 ] || die "usage: mini run <command> [args...]"

    if is_server; then
        "$@"
        return $?
    fi

    require_reachable

    # A login shell so the remote PATH includes Homebrew; without -l, ssh gets
    # a non-interactive shell that has never sourced a profile.
    local quoted
    quoted=$(printf '%q ' "$@")
    ssh -o BatchMode=yes "$MINI_HOST" -- bash -lc "$quoted"
}
