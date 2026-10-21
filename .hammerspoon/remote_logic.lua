-- Pure decision logic for the local/remote toggle. No Hammerspoon APIs here,
-- so it can be tested with plain `lua`.
local M = {}

-- Does a Screen Sharing window title belong to a session with `match`?
-- (The connection browser window is titled "Screen Sharing" and must not match.)
function M.isSessionTitle(title, match)
  if not title or title == "" or not match or match == "" then return false end
  return title:lower():find(match:lower(), 1, true) ~= nil
end

-- What should a button press do?
--   state.remoteFront: Screen Sharing is the frontmost app
--   state.hasSession:  a session window to the remote host is visible to us
-- Returns "back" (return to local), "show" (go to remote), or "connect".
-- Session windows on another Space may be invisible to the Accessibility API,
-- so "connect" must first activate an existing session before opening a new one.
function M.decide(state)
  if state.hasSession and state.remoteFront then return "back" end
  if state.hasSession then return "show" end
  return "connect"
end

return M
