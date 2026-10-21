-- Local/remote desktop toggle: one hotkey (sent by the MX Master 3 gesture
-- button via Logi Options+) flips between the local Space and a full-screen
-- Screen Sharing session to the Mac mini.
local logic = require("remote_logic")

local M = {}
local BUNDLE = "com.apple.ScreenSharing"
local cfg = {}
local lastLocalApp
-- Hammerspoon garbage-collects unreferenced timers/taps, so keep them here.
local keep = {}

local function screenSharing() return hs.application.get(BUNDLE) end

local function sessionWindow()
  local app = screenSharing()
  if not app then return nil end
  for _, w in ipairs(app:allWindows()) do
    if logic.isSessionTitle(w:title(), cfg.match) then return w end
  end
end

local function goRemote(win)
  win:focus()
  if not win:isFullScreen() then win:setFullScreen(true) end
end

local function waitForSession(timeout, onFound, onTimeout)
  local deadline = hs.timer.secondsSinceEpoch() + timeout
  keep.wait = hs.timer.doEvery(0.25, function()
    local w = sessionWindow()
    if w then
      keep.wait:stop(); onFound(w)
    elseif hs.timer.secondsSinceEpoch() > deadline then
      keep.wait:stop(); if onTimeout then onTimeout() end
    end
  end)
end

local function goLocal()
  if lastLocalApp and lastLocalApp:isRunning() then
    lastLocalApp:activate()
  else
    hs.application.launchOrFocusByBundleID("com.apple.finder")
  end
end

local function connect()
  local app = screenSharing()
  if app then app:activate() end
  -- An existing session may be on another Space; activating the app switches
  -- there, after which its window becomes visible to us.
  keep.settle = hs.timer.doAfter(app and 0.5 or 0, function()
    local w = sessionWindow()
    if w then return goRemote(w) end
    hs.urlevent.openURL("vnc://" .. cfg.host)
    waitForSession(60, goRemote, function()
      hs.alert.show("Remote: couldn't connect to " .. cfg.host)
    end)
  end)
end

function M.press()
  local front = hs.application.frontmostApplication()
  local w = sessionWindow()
  local action = logic.decide({
    remoteFront = front ~= nil and front:bundleID() == BUNDLE,
    hasSession = w ~= nil,
  })
  if action == "back" then goLocal()
  elseif action == "show" then goRemote(w)
  else connect() end
end

-- opts: host ("mini.local"), match (window title substring), mods, key
function M.start(opts)
  cfg = opts
  local f = hs.application.frontmostApplication()
  if f and f:bundleID() ~= BUNDLE then lastLocalApp = f end

  keep.watcher = hs.application.watcher.new(function(_, event, app)
    if event == hs.application.watcher.activated and app and app:bundleID() ~= BUNDLE then
      lastLocalApp = app
    end
  end):start()

  -- An event tap (not hs.hotkey) so the combo is swallowed on the Air even
  -- when Screen Sharing is capturing keystrokes for the remote Mac.
  local types = hs.eventtap.event.types
  local keycode = hs.keycodes.map[cfg.key]
  keep.tap = hs.eventtap.new({ types.keyDown, types.keyUp }, function(e)
    if e:getKeyCode() ~= keycode or not e:getFlags():containExactly(cfg.mods) then
      return false
    end
    local repeating = e:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat) ~= 0
    if e:getType() == types.keyDown and not repeating then
      keep.press = hs.timer.doAfter(0, M.press)
    end
    return true
  end):start()

  -- macOS disables taps that are slow to respond; re-enable if that happens.
  keep.guard = hs.timer.doEvery(5, function()
    if not keep.tap:isEnabled() then keep.tap:start() end
  end)
end

return M
