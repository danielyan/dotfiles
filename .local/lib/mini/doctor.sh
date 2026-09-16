# mini doctor — verify every link in the chain and say what to fix.
#
# Read-only: checks state, changes nothing. Each failed check prints the exact
# remedy. Exits non-zero if anything failed, so it works in a script.

mini_doctor() {
    local pass=0 warn=0 fail=0
    _p() { ok "$1"; pass=$((pass+1)); }
    _w() { maybe "$@"; warn=$((warn+1)); }
    _f() { no "$@"; fail=$((fail+1)); }

    local TS_CLI="/Applications/Tailscale.app/Contents/MacOS/Tailscale"

    section "Packages"
    local pkg
    for pkg in tmux mosh syncthing atuin; do
        have "$pkg" && _p "$pkg" || _f "$pkg missing" "brew bundle --file=~/Brewfile"
    done
    [ -d /Applications/Tailscale.app ] && _p "Tailscale.app" \
        || _f "Tailscale.app missing" "brew bundle --file=~/Brewfile, then open it and sign in"

    section "Dotfiles"
    if have yadm; then
        [ -z "$(yadm status --porcelain 2>/dev/null)" ] \
            && _p "yadm working tree clean" || _w "yadm has uncommitted changes" "yadm status"
        yadm fetch --quiet 2>/dev/null
        local behind ahead
        behind=$(yadm rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
        ahead=$(yadm rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
        [ "$behind" -gt 0 ] && _w "yadm is $behind commit(s) behind origin" "yadm pull"
        [ "$ahead"  -gt 0 ] && _w "yadm is $ahead commit(s) ahead of origin"  "yadm push"
        [ "$behind" -eq 0 ] && [ "$ahead" -eq 0 ] && _p "yadm in sync with origin"
    else
        _f "yadm missing" "brew install yadm"
    fi

    section "Network"
    if [ -x "$TS_CLI" ]; then
        "$TS_CLI" status >/dev/null 2>&1 && _p "Tailscale connected" \
            || _f "Tailscale not connected" "open -a Tailscale and sign in"
    else
        _f "Tailscale CLI not found" "install Tailscale.app"
    fi

    if is_server; then
        section "Server role"
        _p "configured as always-on (pmset sleep 0)"
        local n
        n=$(tmux ls 2>/dev/null | wc -l | tr -d ' ')
        [ "${n:-0}" -gt 0 ] && _p "$n tmux session(s) running" \
            || _w "no tmux sessions running yet" "mini connect"

        local vault="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Notes"
        if [ -d "$vault" ]; then
            if find "$vault" -name '*.icloud' -print -quit 2>/dev/null | grep -q .; then
                _w "vault has evicted (placeholder) files" "brctl download \"$vault\""
            else
                _p "vault fully materialised locally"
            fi
        else
            _w "vault not present" "sign into iCloud and wait for sync"
        fi
    else
        section "Reaching the Mini"
        grep -q "config.mini" "$HOME/.ssh/config" 2>/dev/null \
            && _p "~/.ssh/config includes config.mini" \
            || _f "~/.ssh/config does not include config.mini" "yadm bootstrap"

        if reachable; then
            _p "ssh $MINI_HOST"

            # The silent killer: Claude keys session dirs on $HOME, so a
            # different username means transcripts never line up.
            local remote_user
            remote_user=$(ssh -o BatchMode=yes "$MINI_HOST" 'whoami' 2>/dev/null)
            if [ "$remote_user" = "$(whoami)" ]; then
                _p "username matches on both machines ($remote_user)"
            else
                _f "username mismatch: local '$(whoami)' vs mini '$remote_user'" \
                   "Claude session dirs are keyed on \$HOME; transcripts will NOT line up"
            fi

            if ssh -o BatchMode=yes "$MINI_HOST" 'command -v tmux' >/dev/null 2>&1; then
                local sessions
                sessions=$(ssh -o BatchMode=yes "$MINI_HOST" 'tmux ls 2>/dev/null | wc -l' 2>/dev/null | tr -d ' ')
                _p "tmux on mini (${sessions:-0} session(s))"
            else
                _f "tmux not installed on mini" "mini run brew install tmux"
            fi

            if have mosh; then
                ssh -o BatchMode=yes "$MINI_HOST" 'command -v mosh-server' >/dev/null 2>&1 \
                    && _p "mosh available on both ends" \
                    || _w "mosh-server missing on mini" "mini run brew install mosh"
            fi
        else
            _f "cannot ssh to '$MINI_HOST'" "check Tailscale on both ends; is the Mini awake?"
        fi
    fi

    section "Claude state sync"
    [ -f "$HOME/.claude/.stignore" ] && _p "~/.claude/.stignore present" \
        || _f "~/.claude/.stignore missing" "yadm checkout .claude/.stignore"

    if have syncthing; then
        if curl -sf -m 3 -o /dev/null "$SYNCTHING_API/rest/noauth/health"; then
            _p "syncthing running"
            local apikey
            apikey=$(sed -n 's:.*<apikey>\(.*\)</apikey>.*:\1:p' \
                "$HOME/Library/Application Support/Syncthing/config.xml" 2>/dev/null | head -1)
            if [ -n "$apikey" ]; then
                curl -sf -m 5 -H "X-API-Key: $apikey" "$SYNCTHING_API/rest/config/folders" 2>/dev/null \
                    | grep -q '\.claude' \
                    && _p "~/.claude shared in syncthing" \
                    || _f "~/.claude not shared yet" "add it at $SYNCTHING_API and share with the other device"

                local devices
                devices=$(curl -sf -m 5 -H "X-API-Key: $apikey" "$SYNCTHING_API/rest/config/devices" 2>/dev/null \
                          | grep -o '"deviceID"' | wc -l | tr -d ' ')
                [ "${devices:-0}" -gt 1 ] && _p "syncthing paired with ${devices} device(s) incl. self" \
                    || _f "no peer device paired" "pair the other machine at $SYNCTHING_API"

                # Settings that are wrong by default for this folder.
                local folder
                folder=$(curl -sf -m 5 -H "X-API-Key: $apikey" \
                    "$SYNCTHING_API/rest/config/folders" 2>/dev/null \
                    | tr '}' '\n' | grep -A200 '\.claude' | head -40)
                if [ -n "$folder" ]; then
                    echo "$folder" | grep -q '"fsWatcherEnabled":true' \
                        && _p "filesystem watcher on (changes propagate in seconds)" \
                        || _w "filesystem watcher off" "enable 'Watch for Changes' on the folder"
                    if echo "$folder" | grep -q '"type":"none"'; then
                        _w "no file versioning on ~/.claude" \
                           "set Staggered, max age 30d — transcripts are not reproducible"
                    else
                        _p "file versioning enabled"
                    fi
                fi
            fi
        else
            _f "syncthing not running" "brew services start syncthing"
        fi
    fi

    local conflicts
    conflicts=$(find "$HOME/.claude" -name '*sync-conflict*' 2>/dev/null | wc -l | tr -d ' ')
    [ "${conflicts:-0}" -gt 0 ] \
        && _w "$conflicts syncthing conflict file(s) in ~/.claude" "keep the larger, delete the rest" \
        || _p "no sync conflicts"

    section "Shell"
    if have atuin; then
        if [ -f "$HOME/.local/share/atuin/session" ]; then
            _p "atuin logged in"
        elif [ -s "$HOME/.local/share/atuin/history.db" ]; then
            # History imported but no account: registering here is correct.
            _w "atuin has local history but no account" \
               "atuin register -u USER -e EMAIL, then atuin sync, then save 'atuin key'"
        else
            _w "atuin not set up" \
               "on the machine with history: atuin import auto, then register; elsewhere: atuin login -k KEY"
        fi
    fi
    [ -x "$HOME/bin/mini" ] && _p "mini installed" || _f "mini missing" "yadm checkout bin/mini"

    printf '\n%s%d passed, %d warnings, %d failed%s\n' "$C_BOLD" "$pass" "$warn" "$fail" "$C_OFF"
    [ "$fail" -eq 0 ]
}
