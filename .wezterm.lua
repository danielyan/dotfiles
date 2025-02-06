local wezterm = require 'wezterm'

local config = wezterm.config_builder()

config.color_scheme = 'Obsidian'
config.font = wezterm.font 'Fira Code'
return config