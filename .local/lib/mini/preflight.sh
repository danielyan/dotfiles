# mini preflight — prepare this machine to work without the Mini.
#
# Under the remote-first model the Mini is the source of truth and this
# machine's copies are read-mostly. Run before travelling.
#
# Never commits, never pushes, never touches a dirty tree.

mini_preflight() {
    local projects_dir="${PROJECTS_DIR:-$HOME/projects}"
    local clean=0 skipped=0 failed=0

    section "Pulling repos in $projects_dir"
    local dir name out
    for dir in "$projects_dir"/*/; do
        [ -d "$dir/.git" ] || continue
        name=$(basename "$dir")

        if ! git -C "$dir" remote get-url origin >/dev/null 2>&1; then
            maybe "$name — no remote, skipping"; skipped=$((skipped+1)); continue
        fi

        # Refuse to touch a dirty tree; pulling could conflict or stash silently.
        if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
            maybe "$name — uncommitted changes, skipping"; skipped=$((skipped+1)); continue
        fi

        if out=$(git -C "$dir" pull --ff-only --quiet 2>&1); then
            ok "$name"; clean=$((clean+1))
        else
            no "$name — $out"; failed=$((failed+1))
        fi
    done

    section "Refreshing Claude state"
    if ! have syncthing; then
        maybe "syncthing not installed — skipping rescan"
    elif ! curl -sf -m 3 -o /dev/null "$SYNCTHING_API/rest/noauth/health"; then
        maybe "syncthing not responding at $SYNCTHING_API — skipping rescan"
    else
        local apikey
        apikey=$(sed -n 's:.*<apikey>\(.*\)</apikey>.*:\1:p' \
            "$HOME/Library/Application Support/Syncthing/config.xml" 2>/dev/null | head -1)
        if [ -z "$apikey" ]; then
            maybe "could not read syncthing api key — skipping rescan"
        elif curl -sf -m 10 -o /dev/null -X POST \
                -H "X-API-Key: $apikey" "$SYNCTHING_API/rest/db/scan"; then
            ok "syncthing rescan triggered"
        else
            no "syncthing rescan failed"
        fi
    fi

    # iCloud evicts files it thinks are cold and leaves a placeholder that
    # fails to read offline. Force the real bytes local.
    local vault="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Notes"
    if [ -d "$vault" ] && have brctl; then
        brctl download "$vault" >/dev/null 2>&1 && ok "vault pinned locally" \
            || maybe "vault pin failed"
    fi

    printf '\n%spulled:%d  skipped:%d  failed:%d%s\n' "$C_BOLD" "$clean" "$skipped" "$failed" "$C_OFF"
    [ "$failed" -eq 0 ]
}
