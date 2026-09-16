# mini pair — wire Syncthing between this machine and the Mini, end to end.
#
# The chicken-and-egg problem with Syncthing setup is that each device needs the
# other's device ID, which is why the docs tell you to copy-paste it through a
# GUI. We already have ssh to the Mini, so we can just ask it.
#
# Idempotent: re-running reports what already exists and changes nothing.

MINI_FOLDER_ID="${MINI_FOLDER_ID:-claude-state}"
MINI_FOLDER_PATH="${MINI_FOLDER_PATH:-$HOME/.claude}"
# Staggered versioning: 30 days, in seconds. Transcripts are not reproducible.
MINI_VERSION_MAXAGE="${MINI_VERSION_MAXAGE:-2592000}"

_st()        { syncthing cli "$@" 2>/dev/null; }
_st_remote() { ssh -o BatchMode=yes "$MINI_HOST" -- bash -lc "syncthing cli $* 2>/dev/null"; }

_device_id()        { _st show system        | sed -n 's/.*"myID" *: *"\([^"]*\)".*/\1/p'; }
_device_id_remote() { _st_remote show system | sed -n 's/.*"myID" *: *"\([^"]*\)".*/\1/p'; }

# A folder definition must be given in full: `add-json` does NOT merge with
# defaults, it fills anything omitted with Go zero values. Leaving out
# maxConflicts would silently set it to 0, which discards one side's writes
# instead of leaving a conflict copy.
_folder_json() { # $1=peer device id  $2=our device id
    cat <<JSON
{"id":"$MINI_FOLDER_ID","label":"Claude State","filesystemType":"basic",
 "path":"$MINI_FOLDER_PATH","type":"sendreceive",
 "devices":[{"deviceID":"$2","introducedBy":"","encryptionPassword":""},
            {"deviceID":"$1","introducedBy":"","encryptionPassword":""}],
 "rescanIntervalS":3600,"fsWatcherEnabled":true,"fsWatcherDelayS":10,
 "ignorePerms":false,"autoNormalize":true,
 "minDiskFree":{"value":1,"unit":"%"},
 "versioning":{"type":"staggered","params":{"maxAge":"$MINI_VERSION_MAXAGE"},
               "cleanupIntervalS":3600,"fsPath":"","fsType":"basic"},
 "order":"random","ignoreDelete":false,"maxConflicts":10,
 "markerName":".stfolder","copyOwnershipFromParent":false,"paused":false}
JSON
}

_device_json() { # $1=device id  $2=name
    printf '{"deviceID":"%s","name":"%s","addresses":["dynamic"],"compression":"metadata","introducer":false,"paused":false,"autoAcceptFolders":false}' "$1" "$2"
}

mini_pair() {
    have syncthing || die "syncthing not installed — brew bundle --file=~/Brewfile"
    is_server && die "run this from the Air; it drives both ends over ssh"
    curl -sf -m 3 -o /dev/null "$SYNCTHING_API/rest/noauth/health" \
        || die "syncthing not running — brew services start syncthing"
    require_reachable

    section "Identifying both devices"
    local me peer
    me=$(_device_id);        [ -n "$me" ]   || die "could not read this device's ID"
    ok "this machine: $me"

    _st_remote show system >/dev/null 2>&1 \
        || die "syncthing not running on $MINI_HOST — mini run brew services start syncthing"
    peer=$(_device_id_remote); [ -n "$peer" ] || die "could not read $MINI_HOST's device ID"
    ok "$MINI_HOST: $peer"

    # The ignore file is NOT synced by Syncthing — each machine needs its own.
    # Without it on the far end, first sync pulls plugins/ and cache/.
    section "Checking the ignore file on both ends"
    [ -f "$HOME/.claude/.stignore" ] || die "~/.claude/.stignore missing locally — yadm checkout .claude/.stignore"
    ok "local .stignore present"
    ssh -o BatchMode=yes "$MINI_HOST" 'test -f ~/.claude/.stignore' \
        || die "$MINI_HOST has no ~/.claude/.stignore — run 'yadm clone' there FIRST, or first sync will pull plugins/ and cache/"
    ok "$MINI_HOST .stignore present"

    section "Introducing the devices"
    local local_name remote_name
    local_name=$(scutil --get LocalHostName 2>/dev/null || hostname)
    remote_name=$(ssh -o BatchMode=yes "$MINI_HOST" 'scutil --get LocalHostName 2>/dev/null || hostname')

    if _st config devices list | grep -q "$peer"; then
        ok "$MINI_HOST already known here"
    else
        _st config devices add-json "$(_device_json "$peer" "$remote_name")" \
            && ok "added $MINI_HOST here" || no "failed to add $MINI_HOST here"
    fi

    if _st_remote config devices list | grep -q "$me"; then
        ok "this machine already known on $MINI_HOST"
    else
        _st_remote config devices add-json "'$(_device_json "$me" "$local_name")'" \
            && ok "added this machine on $MINI_HOST" || no "failed to add this machine on $MINI_HOST"
    fi

    section "Creating the shared folder"
    if _st config folders list | grep -qx "$MINI_FOLDER_ID"; then
        ok "folder '$MINI_FOLDER_ID' already exists here"
    else
        _st config folders add-json "$(_folder_json "$peer" "$me")" \
            && ok "created '$MINI_FOLDER_ID' here (staggered versioning, 30d)" \
            || no "failed to create folder here"
    fi

    if _st_remote config folders list | grep -qx "$MINI_FOLDER_ID"; then
        ok "folder '$MINI_FOLDER_ID' already exists on $MINI_HOST"
    else
        _st_remote config folders add-json "'$(_folder_json "$me" "$peer")'" \
            && ok "created '$MINI_FOLDER_ID' on $MINI_HOST" \
            || no "failed to create folder on $MINI_HOST"
    fi

    section "Done"
    printf '  Watch the first sync: %s\n' "$SYNCTHING_API"
    printf '  If plugins/ or cache/ appear on the far end, stop — the ignore file is not being read.\n'
    printf '  Verify with: mini doctor\n'
}
