require("hs.ipc") -- enables the `hs` command-line tool

require("remote_desktop").start({
  host = "mini.local",
  match = "mini", -- substring of the Screen Sharing session window title
  mods = { "ctrl", "alt", "cmd", "shift" },
  key = "s", -- Logi Options+ maps the gesture button to ⌃⌥⇧⌘S
})
