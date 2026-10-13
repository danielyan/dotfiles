# A badge at the far left of the prompt naming the machine and how you are on
# it, decided by ~/bin/machine-where (shared with the Claude status line):
#
#   mini, in a tmux/dev session or over ssh/mosh   orange (machine_session)
#   mini, a plain terminal at its own keyboard     teal   (machine_local)
#   the Air, or any other Mac                      grey   (machine_other)
#
# Works inside mosh and tmux, where SSH_TTY never reaches the shell and tide's
# own context item would stay hidden.
#
# Not part of tide: fisher installs every other _tide_* file here, this one is
# tracked in yadm. Colours, icons and the list entry are set in config.fish.
function _tide_item_machine
    set -l where ($HOME/bin/machine-where | string split ' ')
    set -l host $where[1]
    set -l style machine_other
    set -l icon $tide_machine_laptop_icon
    if contains -- $host $tide_machine_server_hosts
        set style machine_$where[2]
        set icon $tide_machine_icon
    end
    _tide_print_item $style $icon'  ' $host
end
