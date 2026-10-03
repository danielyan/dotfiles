# dev doctor — verify every link in the chain and say what to fix.
#
# Read-only: checks state, changes nothing. Each failed check prints the exact
# remedy. Exits non-zero if anything failed, so it works in a script.

# The Syncthing folders that point at ~/.claude, summarised from the JSON of
# /rest/config/folders on stdin. Parsed rather than grepped: the API
# pretty-prints ("fsWatcherEnabled": true, with a space), so the old grep for
# "fsWatcherEnabled":true never matched. The watcher always read as off,
# versioning always as on, and any folder that merely mentioned .claude as
# shared. Prints `count N`, then for the folder shared with the most devices:
# `id`, `devices`, `watcher 0|1`, `versioning TYPE|none`.
_claude_folders() {
    python3 -c '
import json, os, sys
target = os.path.realpath(os.path.expanduser(os.environ.get("CLAUDE_DIR", "~/.claude")))
folders = [f for f in json.load(sys.stdin)
           if os.path.realpath(os.path.expanduser(f.get("path", ""))) == target]
print("count", len(folders))
if folders:
    f = max(folders, key=lambda f: len(f.get("devices", [])))
    print("id", f["id"])
    print("devices", len(f.get("devices", [])))
    print("watcher", int(bool(f.get("fsWatcherEnabled"))))
    print("versioning", (f.get("versioning") or {}).get("type") or "none")
'
}
_cf_field() { printf '%s\n' "$1" | awk -v k="$2" '$1 == k { print $2 }'; }

# One check, one line: `[area] message ✓`, the mark last so the messages line
# up after the tag, and a failure's remedy on the line below.
#   _doctor_line <area> ok|warn|fail <message> [remedy]
_doctor_line() {
    local mark color
    case "$2" in
        ok)   mark='✓'; color=$C_OK ;;
        warn) mark='➞'; color=$C_WARN ;;
        *)    mark='✗'; color=$C_NO ;;
    esac
    printf '%s[%s]%s %s %s%s%s\n' "$C_DIM" "$1" "$C_OFF" "$3" "$color" "$mark" "$C_OFF"
    [ -n "${4:-}" ] && printf '    %s→ %s%s\n' "$C_DIM" "$4" "$C_OFF"
    return 0
}

# Run a slow check with a spinner where its mark will go, then clear the line
# so the result prints in its place. The command's stdout and exit code pass
# straight through, so it works inside $(...): the spinner goes to fd 4, the
# terminal. Only on a terminal, and not under -v, whose debug lines would land
# in the middle of it; otherwise the command just runs.
#   _doctor_spin <area> <label> <command> [args...]
_doctor_spin() {
    local area=$1 label=$2; shift 2
    if [ "${_DOCTOR_TTY:-0}" != 1 ] || [ "${DEV_VERBOSE:-0}" = 1 ]; then
        "$@" 2>/dev/null; return
    fi
    local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) i=0 out pid rc
    out=$(mktemp) || { "$@" 2>/dev/null; return; }
    "$@" > "$out" 2>/dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r%s[%s]%s %s %s%s%s' "$C_DIM" "$area" "$C_OFF" "$label" \
            "$C_WARN" "${frames[i++ % ${#frames[@]}]}" "$C_OFF" >&4
        sleep 0.1
    done
    wait "$pid"; rc=$?
    printf '\r\033[K' >&4
    cat "$out"; rm -f "$out"
    return "$rc"
}

# Which Tailscale this machine has: `app <cli>` for Tailscale.app (its CLI is
# inside the bundle), `brew <cli>` for the formula, whose tailscaled runs as a
# system service and so is up before anyone logs in, or nothing at all.
_tailscale_install() {
    local app="${DEV_TAILSCALE_APP:-/Applications/Tailscale.app}" cli
    if [ -x "$app/Contents/MacOS/Tailscale" ]; then
        printf 'app %s\n' "$app/Contents/MacOS/Tailscale"
    elif cli=$(type -P tailscale); then
        printf 'brew %s\n' "$cli"
    else
        return 1
    fi
}

# How a Tailscale CLI finds its daemon: `ok`, `stale` when the daemon is older
# than the CLI (an upgrade that was never followed by a restart: status still
# works, but warns), or `down`.
#   _tailscale_state <cli>
_tailscale_state() {
    local err
    if err=$("$1" status 2>&1 >/dev/null); then
        case "$err" in
            *"client version"*"server version"*) echo stale ;;
            *) echo ok ;;
        esac
    else
        echo down
    fi
}

dev_doctor() {
    local pass=0 warn=0 fail=0 area=""
    # A blank line between areas, none before the first.
    _area() { [ -n "$area" ] && echo; area=$1; }
    local _DOCTOR_TTY=0
    [ -t 1 ] && _DOCTOR_TTY=1
    exec 4>&1
    _p() { _doctor_line "$area" ok "$1"; pass=$((pass+1)); }
    _w() { _doctor_line "$area" warn "$@"; warn=$((warn+1)); }
    _f() { _doctor_line "$area" fail "$@"; fail=$((fail+1)); }

    local ts_kind="" ts_cli="" ts
    ts=$(_tailscale_install) && read -r ts_kind ts_cli <<< "$ts"
    debug "tailscale: ${ts:-not installed}"

    _area packages
    local pkg
    for pkg in tmux mosh syncthing atuin; do
        have "$pkg" && _p "$pkg" || _f "$pkg missing" "brew bundle --file=~/Brewfile"
    done
    case "$ts_kind" in
        app)  _p "Tailscale (app)" ;;
        brew) _p "Tailscale (brew)" ;;
        *)    _f "Tailscale missing" "brew bundle --file=~/Brewfile, then open it and sign in" ;;
    esac

    _area dotfiles
    if have yadm; then
        [ -z "$(yadm status --porcelain 2>/dev/null)" ] \
            && _p "yadm working tree clean" || _w "yadm has uncommitted changes" "yadm status"
        _doctor_spin "$area" "fetching origin" yadm fetch --quiet
        local behind ahead
        behind=$(yadm rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
        ahead=$(yadm rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
        [ "$behind" -gt 0 ] && _w "yadm is $behind commit(s) behind origin" "yadm pull"
        [ "$ahead"  -gt 0 ] && _w "yadm is $ahead commit(s) ahead of origin"  "yadm push"
        [ "$behind" -eq 0 ] && [ "$ahead" -eq 0 ] && _p "yadm in sync with origin"
    else
        _f "yadm missing" "brew install yadm"
    fi

    _area network
    if [ -n "$ts_cli" ]; then
        case "$(_doctor_spin "$area" "checking Tailscale" _tailscale_state "$ts_cli")" in
            ok)    _p "Tailscale connected" ;;
            stale) _w "Tailscale connected, but tailscaled is older than its CLI" \
                      "sudo brew services restart tailscale" ;;
            *)     if [ "$ts_kind" = brew ]; then
                       _f "Tailscale not connected" "sudo brew services start tailscale, then sudo tailscale up --ssh"
                   else
                       _f "Tailscale not connected" "open -a Tailscale and sign in"
                   fi ;;
        esac
    else
        _f "Tailscale not installed" "brew bundle --file=~/Brewfile"
    fi

    if is_server; then
        _area server
        _p "configured as always-on (pmset sleep 0)"
        local n
        n=$(tmux ls 2>/dev/null | wc -l | tr -d ' ')
        [ "${n:-0}" -gt 0 ] && _p "$n tmux session(s) running" \
            || _w "no tmux sessions running yet" "dev starts main"

        local vault="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Notes"
        if [ -d "$vault" ]; then
            if _doctor_spin "$area" "looking for evicted vault files" \
                    find "$vault" -name '*.icloud' -print -quit | grep -q .; then
                _w "vault has evicted (placeholder) files" "brctl download \"$vault\""
            else
                _p "vault fully materialised locally"
            fi
        else
            _w "vault not present" "sign into iCloud and wait for sync"
        fi
    else
        _area mini
        grep -q "config.mini" "$HOME/.ssh/config" 2>/dev/null \
            && _p "~/.ssh/config includes config.mini" \
            || _f "~/.ssh/config does not include config.mini" "yadm bootstrap"

        if _doctor_spin "$area" "reaching $DEV_HOST" reachable; then
            _p "ssh $DEV_HOST"

            # The silent killer: Claude keys session dirs on $HOME, so a
            # different username means transcripts never line up.
            local remote_user
            remote_user=$(_doctor_spin "$area" "comparing usernames" \
                ssh -o BatchMode=yes "$DEV_HOST" 'whoami')
            if [ "$remote_user" = "$(whoami)" ]; then
                _p "username matches on both machines ($remote_user)"
            else
                _f "username mismatch: local '$(whoami)' vs mini '$remote_user'" \
                   "Claude session dirs are keyed on \$HOME; transcripts will NOT line up"
            fi

            if _doctor_spin "$area" "looking for tmux on $DEV_HOST" \
                    remote_ok 'command -v tmux'; then
                local sessions
                sessions=$(_doctor_spin "$area" "counting sessions on $DEV_HOST" \
                    ssh -o BatchMode=yes "$DEV_HOST" 'tmux ls 2>/dev/null | wc -l' | tr -d ' ')
                _p "tmux on mini (${sessions:-0} session(s))"
            else
                _f "tmux not installed on mini" "dev run brew install tmux"
            fi

            if have mosh; then
                _doctor_spin "$area" "looking for mosh-server on $DEV_HOST" \
                    remote_ok 'command -v mosh-server' \
                    && _p "mosh available on both ends" \
                    || _w "mosh-server missing on mini" "dev run brew install mosh"
            fi
        else
            _f "cannot ssh to '$DEV_HOST'" "check Tailscale on both ends; is the Mini awake?"
        fi
    fi

    _area claude-sync
    [ -f "$HOME/.claude/.stignore" ] && _p "~/.claude/.stignore present" \
        || _f "~/.claude/.stignore missing" "yadm checkout .claude/.stignore"

    if have syncthing; then
        if _doctor_spin "$area" "asking syncthing" \
                curl -sf -m 3 -o /dev/null "$SYNCTHING_API/rest/noauth/health"; then
            _p "syncthing running"
            local apikey
            apikey=$(sed -n 's:.*<apikey>\(.*\)</apikey>.*:\1:p' \
                "$HOME/Library/Application Support/Syncthing/config.xml" 2>/dev/null | head -1)
            if [ -n "$apikey" ]; then
                local report count
                report=$(_doctor_spin "$area" "reading syncthing's folders" \
                         curl -sf -m 5 -H "X-API-Key: $apikey" "$SYNCTHING_API/rest/config/folders" \
                         | _claude_folders 2>/dev/null)
                count=$(_cf_field "$report" count)
                debug "syncthing folders for ~/.claude: $(printf '%s' "$report" | tr '\n' ' ')"
                if [ "${count:-0}" -eq 0 ]; then
                    _f "~/.claude not shared yet" "dev pair"
                else
                    [ "$count" -gt 1 ] && _w "$count syncthing folders point at ~/.claude" \
                        "keep '$(_cf_field "$report" id)' and remove the others; removing one deletes the shared .stfolder marker, so then: mkdir ~/.claude/.stfolder"
                    [ "$(_cf_field "$report" devices)" -gt 1 ] \
                        && _p "~/.claude shared in syncthing" \
                        || _f "~/.claude is in syncthing but shared with no other device" "dev pair"
                fi

                local devices
                devices=$(_doctor_spin "$area" "reading syncthing's devices" \
                          curl -sf -m 5 -H "X-API-Key: $apikey" "$SYNCTHING_API/rest/config/devices" \
                          | grep -o '"deviceID"' | wc -l | tr -d ' ')
                [ "${devices:-0}" -gt 1 ] && _p "syncthing paired with ${devices} device(s) incl. self" \
                    || _f "no peer device paired" "pair the other machine at $SYNCTHING_API"

                # Settings that are wrong by default for this folder.
                if [ "${count:-0}" -gt 0 ]; then
                    [ "$(_cf_field "$report" watcher)" = 1 ] \
                        && _p "filesystem watcher on (changes propagate in seconds)" \
                        || _w "filesystem watcher off" "enable 'Watch for Changes' on the folder"
                    if [ "$(_cf_field "$report" versioning)" = none ]; then
                        _w "no file versioning on ~/.claude" \
                           "set Staggered, max age 30d — transcripts are not reproducible"
                    else
                        _p "file versioning enabled ($(_cf_field "$report" versioning))"
                    fi
                fi
            fi
        else
            _f "syncthing not running" "brew services start syncthing"
        fi
    fi

    local conflicts
    conflicts=$(_doctor_spin "$area" "looking for sync conflicts" \
        find "$HOME/.claude" -name '*sync-conflict*' | wc -l | tr -d ' ')
    [ "${conflicts:-0}" -gt 0 ] \
        && _w "$conflicts syncthing conflict file(s) in ~/.claude" "keep the larger, delete the rest" \
        || _p "no sync conflicts"

    _area shell
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
    [ -x "$HOME/bin/dev" ] && _p "dev installed" || _f "dev missing" "yadm checkout bin/dev"

    printf '\n%s%d passed, %d warnings, %d failed%s\n' "$C_BOLD" "$pass" "$warn" "$fail" "$C_OFF"
    [ "$fail" -eq 0 ]
}
