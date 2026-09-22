# Terminal/tab title for plain shell sessions: just the current folder.
# Claude Code sessions override this via hooks in ~/.claude/settings.json,
# which render "<glyph> 🤖 <folder>"; fish repaints this on the next prompt
# once Claude exits.
function fish_title
    basename $PWD
end
