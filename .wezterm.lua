local wezterm = require 'wezterm'

local config = wezterm.config_builder()

config.color_scheme = 'Obsidian'
config.font = wezterm.font 'Fira Code'

config.font_size = 13

config.window_decorations = "RESIZE"
config.window_background_opacity = 0.90
config.macos_window_background_blur = 10
config.initial_rows = 30
config.initial_cols = 120

return config