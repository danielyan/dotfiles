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

#------ misc
abbr --add l ls -la --color | awk '{k=0;for(i=0;i<=8;i++)k+=((substr($1,i+2,1)~/[rwx]/)*2^(8-i));if(k)printf(" %0o ",k);print}'
