# dev repos — the list of git repos that belong in ~/projects, and cloning it.
# Usage is in _repos_usage below; `dev repos help` prints it.
#
# The list is kept by hand, never derived: ~/projects also holds scratch
# folders and clones not wanted everywhere. It lives in ~/.config/dev/repos,
# one "<name> <url>" per line, and is in yadm's encrypt list, so it travels
# encrypted: after changing it, `yadm encrypt` and commit the archive.
#
# Works on whichever machine runs it, so bootstrap can call it locally; for the
# Mini from elsewhere, `dev run dev repos sync`. It only ever clones into a
# folder that does not exist: an existing folder is reported, never changed.

DEV_REPOS_FILE="${DEV_REPOS_FILE:-$HOME/.config/dev/repos}"
DEV_PROJECTS_DIR="${DEV_PROJECTS_DIR:-$HOME/projects}"

_repos_usage() {
    cat <<USAGE
${C_BOLD}dev repos${C_OFF} — the repos ~/projects should hold

  ${C_BOLD}dev repos${C_OFF} [list]                  every entry, and whether it is cloned here
  ${C_BOLD}dev repos add${C_OFF} <entry>...          add repos; each entry is a URL, or the name
                                    or path of a clone already here (its origin)
  ${C_BOLD}dev repos add --as${C_OFF} <name> <url>   add one repo under a folder name of your own
  ${C_BOLD}dev repos remove${C_OFF} <name>...        drop entries from the list; clones are untouched
  ${C_BOLD}dev repos sync${C_OFF}                    clone whatever is missing
  ${C_BOLD}dev repos status${C_OFF}                  like list; exits 2 when anything is missing
  ${C_BOLD}dev repos help${C_OFF}                    this

The list is $DEV_REPOS_FILE, encrypted by yadm:
after changing it, run yadm encrypt and commit the archive.
USAGE
}

# Entries as "name<TAB>url", skipping blanks and comments.
_repos_entries() {
    [ -f "$DEV_REPOS_FILE" ] || return 0
    awk '!/^[[:space:]]*(#|$)/ { print $1 "\t" $2 }' "$DEV_REPOS_FILE"
}

# Comparable form of a remote: no trailing slash or .git, host lower-cased, so
# https://github.com/x/y.git and https://GitHub.com/x/y/ are the same repo.
_repos_norm() {
    printf '%s\n' "$1" | sed -E 's#/+$##; s#\.git$##' \
        | awk -F/ 'BEGIN{OFS="/"} NF >= 3 { $3 = tolower($3) } { print }'
}

_repos_name_from_url() { basename "$(_repos_norm "$1")"; }

_repos_valid_name() {
    case "$1" in
        ''|.*|*/*|*[[:space:]]*) return 1 ;;
    esac
}

# One of: ok, missing, other-remote, not-a-repo.
_repos_state() { # $1=name $2=url
    local dir="$DEV_PROJECTS_DIR/$1" origin
    [ -e "$dir" ] || { echo missing; return; }
    [ -d "$dir/.git" ] || { echo not-a-repo; return; }
    origin=$(git -C "$dir" remote get-url origin 2>/dev/null)
    if [ "$(_repos_norm "$origin")" = "$(_repos_norm "$2")" ]; then
        echo ok
    else
        debug "$1: origin $(_repos_norm "$origin") is not the listed $(_repos_norm "$2") (compared without .git or a trailing /)"
        echo other-remote
    fi
}

_repos_write_hint() {
    printf '  %s→ travels encrypted: yadm encrypt, then commit ~/.local/share/yadm/archive%s\n' \
        "$C_DIM" "$C_OFF"
}

# Adds one entry: $1 is a URL, or the name or path of a clone already here;
# $2 an optional folder name. Returns 1 on a problem, having said why.
_repos_add_one() {
    local url name
    case "$1" in
        *://*|git@*:*)
            url=$1
            name=${2:-$(_repos_name_from_url "$url")}
            ;;
        *)
            local dir=$1
            [ -d "$dir" ] || dir="$DEV_PROJECTS_DIR/$1"
            [ -d "$dir/.git" ] || { no "$1 is neither a URL nor a git repo in $DEV_PROJECTS_DIR"; return 1; }
            url=$(git -C "$dir" remote get-url origin 2>/dev/null) \
                || { no "$(basename "$dir") has no origin remote, so there is nothing to clone elsewhere"; return 1; }
            name=${2:-$(basename "$dir")}
            ;;
    esac
    _repos_valid_name "$name" || { no "'$name' is not usable as a folder name"; return 1; }

    local existing
    existing=$(_repos_entries | awk -F'\t' -v n="$name" '$1 == n { print $2 }')
    if [ -n "$existing" ]; then
        [ "$(_repos_norm "$existing")" = "$(_repos_norm "$url")" ] \
            && { ok "$name is already listed"; return 0; }
        no "$name is already listed as $existing"
        return 1
    fi

    mkdir -p "$(dirname "$DEV_REPOS_FILE")"
    if [ ! -f "$DEV_REPOS_FILE" ]; then
        (umask 077; printf '# Repos that belong in ~/projects: <name> <url>. Edit with `dev repos`.\n' \
            > "$DEV_REPOS_FILE")
    fi
    printf '%s %s\n' "$name" "$url" >> "$DEV_REPOS_FILE"
    ok "added $name  $url"
}

_repos_add() {
    local as=""
    if [ "${1:-}" = "--as" ]; then
        [ $# -eq 3 ] || die "usage: dev repos add --as <name> <url>  (one repo at a time)"
        as=$2; shift 2
    fi
    [ $# -ge 1 ] || die "usage: dev repos add <url|name|path>...  (dev repos help)"

    # Every entry is tried, so one typo does not lose the rest.
    local entry failed=0
    for entry in "$@"; do
        _repos_add_one "$entry" "$as" || failed=$((failed + 1))
    done
    _repos_write_hint
    [ "$failed" -eq 0 ]
}

_repos_remove() {
    [ $# -ge 1 ] || die "usage: dev repos remove <name>...  (dev repos help)"
    local name failed=0 tmp
    for name in "$@"; do
        if ! _repos_entries | awk -F'\t' -v n="$name" '$1 == n { f = 1 } END { exit !f }'; then
            no "$name is not in the list (dev repos list)"
            failed=$((failed + 1))
            continue
        fi
        tmp=$(mktemp "$DEV_REPOS_FILE.XXXXXX") || die "cannot write next to $DEV_REPOS_FILE"
        # Keep comments and everything else exactly as they were.
        awk -v n="$name" '/^[[:space:]]*(#|$)/ || $1 != n' "$DEV_REPOS_FILE" > "$tmp" \
            && chmod 600 "$tmp" && mv "$tmp" "$DEV_REPOS_FILE"
        ok "removed $name from the list"
        [ -e "$DEV_PROJECTS_DIR/$name" ] \
            && printf '  %s→ %s itself is untouched%s\n' "$C_DIM" "$DEV_PROJECTS_DIR/$name" "$C_OFF"
    done
    _repos_write_hint
    [ "$failed" -eq 0 ]
}

# Prints each entry with its state; returns 2 when something is missing, so
# bootstrap can ask only when there is work to do.
_repos_list() {
    [ -f "$DEV_REPOS_FILE" ] || {
        maybe "no repo list yet" "dev repos add <url>  (it lives in $DEV_REPOS_FILE)"
        return 0
    }
    if [ -z "$(_repos_entries)" ]; then
        maybe "the repo list is empty" "dev repos add <url>"
        return 0
    fi
    local name url state missing=0
    while IFS=$'\t' read -r name url; do
        state=$(_repos_state "$name" "$url")
        case $state in
            ok)           ok "$name" ;;
            missing)      maybe "$name — not cloned" "$url"; missing=$((missing + 1)) ;;
            other-remote) no "$name — $DEV_PROJECTS_DIR/$name has a different origin" \
                              "expected $url" ;;
            not-a-repo)   no "$name — $DEV_PROJECTS_DIR/$name exists but is not a git repo" ;;
        esac
    done < <(_repos_entries)
    [ "$missing" -eq 0 ] || return 2
}

_repos_clone() { # $1=url $2=dir
    # gh authenticates a private GitHub clone with its own login, without
    # touching the tracked .gitconfig. Everything else is plain git.
    case "$1" in
        https://github.com/*|git@github.com:*)
            if have gh && gh auth status >/dev/null 2>&1; then
                debug "cloning with gh: it brings its own GitHub login"
                gh repo clone "$1" "$2" -- --quiet
                return
            fi
            debug "cloning with plain git: gh is not installed or not logged in, so a private repo will fail"
            ;;
    esac
    git clone --quiet "$1" "$2"
}

_repos_sync() {
    [ -f "$DEV_REPOS_FILE" ] || die "no repo list at $DEV_REPOS_FILE (dev repos add <url>)"
    mkdir -p "$DEV_PROJECTS_DIR"
    local name url state failed=0 cloned=0
    while IFS=$'\t' read -r name url; do
        state=$(_repos_state "$name" "$url")
        case $state in
            ok) ;;
            missing)
                if _repos_clone "$url" "$DEV_PROJECTS_DIR/$name" </dev/null; then
                    ok "cloned $name"; cloned=$((cloned + 1))
                else
                    no "could not clone $name" "$url — private? gh auth login"
                    failed=$((failed + 1))
                fi
                ;;
            other-remote) maybe "$name left alone: $DEV_PROJECTS_DIR/$name has a different origin" ;;
            not-a-repo)   maybe "$name left alone: $DEV_PROJECTS_DIR/$name is not a git repo" ;;
        esac
    done < <(_repos_entries)
    [ "$cloned" -eq 0 ] && [ "$failed" -eq 0 ] && ok "everything listed is already here"
    [ "$failed" -eq 0 ]
}

dev_repos() {
    debug "repo list: $DEV_REPOS_FILE ($(_repos_entries | grep -c . | tr -d ' ') entries), projects in $DEV_PROJECTS_DIR"
    local sub="${1:-list}"
    [ $# -gt 0 ] && shift
    case "$sub" in
        list|status)        _repos_list ;;
        add)                _repos_add "$@" ;;
        remove|rm)          _repos_remove "$@" ;;
        sync)               _repos_sync ;;
        help|-h|--help)     _repos_usage ;;
        *)
            printf '%sdev:%s unknown: dev repos %s\n\n' "$C_NO" "$C_OFF" "$sub" >&2
            _repos_usage >&2
            exit 1
            ;;
    esac
}
