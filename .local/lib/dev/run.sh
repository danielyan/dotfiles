# dev run — run one command on the Mini and come straight back.
#
# For things that do not deserve a session: `dev run brew upgrade`,
# `dev run git -C projects/magpie status`.

dev_run() {
    [ $# -gt 0 ] || die "usage: dev run <command> [args...]"

    if is_server; then
        "$@"
        return $?
    fi

    require_reachable

    # %q quotes each argument for the bash that runs the line on the Mini.
    remote_bash "$(printf '%q ' "$@")"
}
