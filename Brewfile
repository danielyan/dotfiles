brew "fish"
brew "yt-dlp"
brew "batt"
brew "fisher"
brew "gh"
brew "yadm"
brew "node"
brew "ffmpeg"
brew "poppler"
brew "uv"
brew "xcodegen"
brew "platformio"
brew "mas"
brew "utiluti"         # default apps for file types; see bin/mac-default-apps

# --- machine continuity: see vault projects/project-machine-continuity.md ---
brew "tmux"          # persistent sessions on the Mini (the continuity mechanism)
brew "mosh"          # survives lid-close and network changes
brew "syncthing"     # ~/.claude runtime state between machines
brew "atuin"         # shell history synced across machines
brew "jq"
brew "gnupg"     # yadm encrypt/decrypt
brew "pam-reattach"  # Touch ID for sudo inside tmux; see bootstrap

cask "font-fira-code"
cask "font-iosevka"
cask "iina"
cask "alfred"
cask "appcleaner"
cask "beyond-compare"
cask "bitwarden"
cask "hiddenbar"
cask "itsycal"
cask "keka"
cask "rectangle"
cask "shottr"
cask "spotify"
cask "telegram"
cask "todoist-app"
cask "codex"
# cask "virtualbuddy"
cask "visual-studio-code"
# cask "microsoft-edge"
cask "google-chrome"
cask "obsidian"
cask "font-meslo-lg-nerd-font"
# cask "grandperspective"
cask "ghostty"
cask "brave-browser"
cask "discord"
cask "claude"
cask "synology-drive"
cask "bambu-studio"
cask "claude-code"
# Mesh network + Tailscale SSH. The Mini (yadm class "server") takes the
# formula: its tailscaled is a system service, up before anyone logs in, so
# after a reboot the Mini is reachable without a login. Bootstrap starts it
# as root; `restart_service:` here would start it as a per-user agent.
# Elsewhere the app, which signs in through the menu bar.
# brew runs this with a bare system PATH, so yadm needs its full path; tests
# point HOMEBREW_YADM (brew passes HOMEBREW_* through) at a stub.
yadm = ENV.fetch("HOMEBREW_YADM", "#{HOMEBREW_PREFIX}/bin/yadm")
if `"#{yadm}" config --get-all local.class 2>/dev/null`.split.include?("server")
  brew "tailscale"
else
  cask "tailscale-app"
end
cask "danielyan/tap/fresco"  # own app; updates itself via Sparkle

mas "Brother iPrint&Scan", id: 1193539993
