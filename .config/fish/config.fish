if status is-interactive
    # Commands to run in interactive sessions can go here
end

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
export PATH="$HOME/.local/bin:$PATH"

#------ project shortcuts: type folder name to cd into ~/projects/<name>
for dir in ~/projects/*/
    set -l name (basename $dir)
    function $name --inherit-variable dir; cd $dir; end
end

#------ claude wrapper
function claude --wraps claude
    set -l project_name (basename $PWD)
    command claude --name $project_name $argv
end

#------ knowledge base
alias kb 'claude --dangerously-skip-permissions --allowedTools "Read" "Glob" "Grep" "Bash(ls *)" "Skill" --append-system-prompt "Read-only knowledge base mode. Never create, edit, or delete files."'
alias kbq 'claude -p --dangerously-skip-permissions --allowedTools "Read" "Glob" "Grep" "Bash(ls *)" "Skill" --append-system-prompt "Read-only knowledge base mode. Never create, edit, or delete files."'
