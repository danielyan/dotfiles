# A badge at the far left of the prompt naming the machine, shown only on the
# always-on Mini. On the laptop it prints nothing, so its appearing at all is
# the signal. Mirrors tide's own context item, which hides itself the same way,
# but works inside mosh and tmux, where SSH_TTY never reaches the shell and
# context would stay hidden.
#
# Not part of tide: fisher installs every other _tide_* file here, this one is
# tracked in yadm. Colours and the list entry are set in config.fish.
function _tide_item_machine
    set -l host (string split -m1 . -- $hostname)[1]
    contains -- $host $tide_machine_show_on || return
    _tide_print_item machine $tide_machine_icon' ' $host
end
