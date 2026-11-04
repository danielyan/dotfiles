# dev hub — every session on the Mini in one screen, listed down the left like
# browser tabs, the one picked live on the right.
#
#   dev hub                attach to the hub, starting it if need be
#
# The hub is a tmux server of its own (tmux -L hub, configured by
# ~/.config/dev/hub.tmux.conf). Its left pane runs dev-hub, the sidebar, built
# from ~/.local/src/dev-hub; its right pane is a nested client of whichever
# real session is picked. Sessions stay on the default server, so `dev <name>`
# reaches them exactly as before, and ending the hub ends none of them.
#
# dev-hub is Rust and only the Mini runs it, so only the Mini builds it: the
# first `dev hub`, and the first after its source changes (a yadm pull), runs
# cargo there and says so. See vault: projects/project-machine-continuity.md

# _run_tmux.
# shellcheck source=/dev/null
. "$DEV_LIB/connect.sh"

DEV_HUB_SRC="${DEV_HUB_SRC:-$HOME/.local/src/dev-hub}"
DEV_HUB_BIN="${DEV_HUB_BIN:-$HOME/.local/bin/dev-hub}"
DEV_HUB_CONF="${DEV_HUB_CONF:-$HOME/.config/dev/hub.tmux.conf}"

# Build dev-hub if it is missing or older than its source; prints __dev_ok on
# stdout when there is a current one. cargo's progress goes to stderr, so it
# is seen, and over ssh it comes back that way too. Rustup's cargo is
# keg-only: off PATH unless the shell profile put it there.
_hub_build_script() {
    cat <<SCRIPT
src=$(printf '%q' "$DEV_HUB_SRC"); bin=$(printf '%q' "$DEV_HUB_BIN")
[ -f "\$src/Cargo.toml" ] || { echo "no dev-hub source at \$src (yadm pull)" >&2; exit 0; }
if [ ! -x "\$bin" ] || [ -n "\$(find "\$src/src" "\$src/Cargo.toml" "\$src/Cargo.lock" -newer "\$bin" -print -quit 2>/dev/null)" ]; then
    cargo=\$(command -v cargo || echo /opt/homebrew/opt/rustup/bin/cargo)
    echo "building dev-hub (first run, or its source changed) …" >&2
    # From the source folder, so its .cargo/config.toml keeps the build in
    # ~/.cache/dev-hub, warm for the next rebuild.
    (cd "\$src" && "\$cargo" install --quiet --locked --force --path . --root "\${bin%/bin/*}") >&2 || exit 0
fi
echo __dev_ok
SCRIPT
}

_hub_ready() {
    local out
    if is_server; then
        out=$(bash -c "$(_hub_build_script)")
    else
        out=$(remote_bash "$(_hub_build_script)")
    fi
    printf '%s\n' "$out" | grep -qx __dev_ok
}

dev_hub() {
    [ $# -eq 0 ] || die "dev hub takes nothing: sessions are opened, started and killed from inside it"
    is_server || require_reachable
    _hub_ready || die "dev-hub could not be built on $DEV_HOST (cargo's output is above)"
    # -f only applies when the hub's server starts; a running hub is attached
    # as it is, and `new -A` starts one with the sidebar in its first pane.
    _run_tmux tmux -L hub -f "$DEV_HUB_CONF" new -A -s hub -n hub "$DEV_HUB_BIN"
}
