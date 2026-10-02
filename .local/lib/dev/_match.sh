# Matching what was typed against what exists: commands, sessions, project
# folders. Sourced by bin/dev. It defines no dev_ function and is not in
# COMMANDS, so it is never run as a subcommand.

# Edit distance between two words, a swap of neighbours counting as one edit:
# magpei → magpie is 1, not the 2 plain Levenshtein says. One awk function,
# shared by both helpers below.
_DIST_AWK='
    function dist(a, b,    la, lb, i, j, c, x, y, z, m, d) {
        la = length(a); lb = length(b)
        for (i = 0; i <= la; i++) d[i, 0] = i
        for (j = 0; j <= lb; j++) d[0, j] = j
        for (i = 1; i <= la; i++) for (j = 1; j <= lb; j++) {
            c = (substr(a, i, 1) != substr(b, j, 1))
            x = d[i-1, j] + 1; y = d[i, j-1] + 1; z = d[i-1, j-1] + c
            m = (x < y ? x : y); m = (m < z ? m : z)
            if (i > 1 && j > 1 && substr(a, i, 1) == substr(b, j-1, 1) \
                && substr(a, i-1, 1) == substr(b, j, 1) && d[i-2, j-2] + 1 < m)
                m = d[i-2, j-2] + 1
            d[i, j] = m
        }
        return d[la, lb]
    }
'

#   _distance <a> <b>
_distance() {
    awk -v a="$1" -v b="$2" "$_DIST_AWK"' BEGIN { print dist(a, b) }'
}

# How far a typo may be from what was meant: short words tolerate one slip,
# longer ones two.
_typo_limit() { [ ${#1} -le 4 ] && echo 1 || echo 2; }

# The candidates <word> most plausibly means, ignoring case. Tries, in order,
# and stops at the first that finds any: the same word, words it starts,
# words that contain it, and words within _typo_limit edits (only those at the
# smallest distance). Prints them, one per line, in the candidates' order;
# prints nothing and returns 1 when nothing is close.
#   _best_matches <word> <candidate>...
_best_matches() {
    local word=$1
    shift
    [ $# -gt 0 ] || return 1
    printf '%s\n' "$@" | awk -v w="$word" -v limit="$(_typo_limit "$word")" "$_DIST_AWK"'
    NF { cand[++n] = $0 }
    END {
        lw = tolower(w)
        for (t = 1; t <= 3; t++) {
            found = 0
            for (i = 1; i <= n; i++) {
                lc = tolower(cand[i])
                if ((t == 1 && lc == lw) || (t == 2 && index(lc, lw) == 1) \
                    || (t == 3 && index(lc, lw) > 0)) { print cand[i]; found = 1 }
            }
            if (found) exit 0
        }
        best = limit + 1
        for (i = 1; i <= n; i++) { dd[i] = dist(lw, tolower(cand[i])); if (dd[i] < best) best = dd[i] }
        if (best > limit) exit 1
        for (i = 1; i <= n; i++) if (dd[i] == best) print cand[i]
    }'
}
