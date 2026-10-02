# dev shell — a plain login shell on the Mini, no tmux.
#
# The escape hatch for when tmux itself is the thing that is broken.

dev_shell() {
    is_server && die "already on the Mini"
    require_reachable
    debug "\$ ssh -t $DEV_HOST"
    exec ssh -t "$DEV_HOST"
}
