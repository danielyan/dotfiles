if status is-interactive
    # gpg needs to know which terminal to ask for a passphrase in, or
    # `yadm encrypt` dies with "Inappropriate ioctl for device".
    set -gx GPG_TTY (tty)

    # Put the machine badge first (functions/_tide_item_machine.fish),
    # ahead of whatever `tide configure` chose. A global, so rerunning tide
    # configure cannot drop it; interactive only, so bootstrap's
    # non-interactive `tide configure --auto` never sees the shadowing global.
    contains machine $tide_left_prompt_items
    or set -g tide_left_prompt_items machine $tide_left_prompt_items
end

# The machine badge: which hosts show it, and how it looks. Outside the
# interactive block because tide draws the prompt in a background `fish -c`.
set -g tide_machine_show_on mini
set -g tide_machine_icon \uf108
set -g tide_machine_bg_color D75F00
set -g tide_machine_color EEEEEE

fish_add_path /opt/homebrew/bin

fish_config theme choose ayu\ Dark
set fish_greeting

#------ yadm
abbr --add ys yadm status
abbr --add yc --position anywhere --set-cursor "yadm commit -m \"%\""
abbr --add ya yadm add
abbr --add yl yadm lg
abbr --add yd yadm diff
abbr --add yp yadm pull
abbr --add ypp yadm push 

#------ git
abbr --add gs git status
abbr --add gc --position anywhere --set-cursor "git commit -m \"%\""
abbr --add ga git add
abbr --add gl git lg
abbr --add gd git diff
abbr --add gp git pull
abbr --add gpp git push

#------ npm
abbr --add nrc "clear && npm run check"
abbr --add nrd "clear && npm run dev"

#------ misc
abbr --add l ls -la --color | awk '{k=0;for(i=0;i<=8;i++)k+=((substr($1,i+2,1)~/[rwx]/)*2^(8-i));if(k)printf(" %0o ",k);print}'

abbr --add reset_fcp mv -v "~/Library/Containers/com.apple.FinalCutTrial/Data/Library/Application\ Support/.ffuserdata" ~/.Trash

abbr --add yt --position anywhere --set-cursor "yt-dlp \"%\""
fish_add_path $HOME/bin
fish_add_path --move $HOME/.local/bin

#------ atuin: shell history shared across machines
if status is-interactive; and command -q atuin
    atuin init fish | source
end

#------ project shortcuts: type folder name to cd into ~/projects/<name>
for dir in ~/projects/*/
    set -l name (basename $dir)
    function $name --inherit-variable dir; cd $dir; end
end

#------ knowledge base
alias kb 'claude --dangerously-skip-permissions --allowedTools "Read" "Glob" "Grep" "Bash(ls *)" "Skill" --append-system-prompt "Read-only knowledge base mode. Never create, edit, or delete files."'
alias kbq 'claude -p --dangerously-skip-permissions --allowedTools "Read" "Glob" "Grep" "Bash(ls *)" "Skill" --append-system-prompt "Read-only knowledge base mode. Never create, edit, or delete files."'
