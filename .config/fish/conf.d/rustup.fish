# Homebrew's rustup is keg-only (it conflicts with the rust formula), so its
# cargo, rustc and rustup are not linked into /opt/homebrew/bin.
fish_add_path /opt/homebrew/opt/rustup/bin
