-- Run: lua ~/.hammerspoon/tests/remote_logic_test.lua
local dir = arg[0]:match("^(.*)/tests/") or "."
package.path = dir .. "/?.lua;" .. package.path
local logic = require("remote_logic")

local failures, count = 0, 0
local function eq(actual, expected, name)
  count = count + 1
  if actual ~= expected then
    failures = failures + 1
    print(("FAIL %s: expected %s, got %s"):format(name, tostring(expected), tostring(actual)))
  end
end

-- isSessionTitle
eq(logic.isSessionTitle("mini", "mini"), true, "exact title")
eq(logic.isSessionTitle("Mini (High Performance)", "mini"), true, "case-insensitive substring")
eq(logic.isSessionTitle("Screen Sharing", "mini"), false, "browser window")
eq(logic.isSessionTitle("", "mini"), false, "empty title")
eq(logic.isSessionTitle(nil, "mini"), false, "nil title")
eq(logic.isSessionTitle("mini", ""), false, "empty match")
eq(logic.isSessionTitle("mini.local", "mini.local"), true, "dot is literal")
eq(logic.isSessionTitle("miniXlocal", "mini.local"), false, "dot not a pattern")

-- decide
eq(logic.decide({ hasSession = true, remoteFront = true }), "back", "remote in front -> back")
eq(logic.decide({ hasSession = true, remoteFront = false }), "show", "session behind -> show")
eq(logic.decide({ hasSession = false, remoteFront = false }), "connect", "no session -> connect")
eq(logic.decide({ hasSession = false, remoteFront = true }), "connect", "browser window front -> connect")

print(("%d/%d passed"):format(count - failures, count))
os.exit(failures == 0 and 0 or 1)
