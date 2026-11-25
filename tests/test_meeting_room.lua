-- Exercises examples/meeting-room.lua against fake components.
local Q = dofile("tests/qsys_mock.lua")
local pass = 0
local function ok(cond, msg) assert(cond, msg); pass = pass + 1 end

local function fakeComponent()
  local log = {}
  local comp = setmetatable({}, { __index = function(t, name)
    local c = { Boolean = false, Value = 0, triggers = 0, name = name }
    function c:Trigger() self.triggers = self.triggers + 1; log[#log + 1] = name .. ":trigger" end
    rawset(t, name, c)
    return c
  end })
  return comp, log
end

local shelly = fakeComponent()
local dali = fakeComponent()
Component = { New = function(name) return name:find("Shelly") and shelly or dali end }
print = function() end
dofile("examples/meeting-room.lua")

local function fire(c) c.EventHandler(c) end

-- Short press: btn_down, btn_up, single_push.
shelly.Input1Held.Boolean = true; fire(shelly.Input1Held)
Q.advance(0.2)
shelly.Input1Held.Boolean = false; fire(shelly.Input1Held)
fire(shelly.Input1Push)
ok(dali.Group1On.Boolean == true, "short press toggles on")
fire(shelly.Input1Push)
ok(dali.Group1On.Boolean == false, "second press toggles off")

-- Hold from off: dims up, release stops, the trailing push does not toggle.
dali.Group1Level.Value = 0
shelly.Input1Held.Boolean = true; fire(shelly.Input1Held)
Q.advance(0.5)
ok(dali.Group1Raise.Boolean == true and dali.Group1Lower.Boolean == false, "hold from off raises")
fire(shelly.Input1LongPush)
shelly.Input1Held.Boolean = false; fire(shelly.Input1Held)
ok(dali.Group1Raise.Boolean == false, "release stops raise")
dali.Group1On.Boolean = true
fire(shelly.Input1Push)
ok(dali.Group1On.Boolean == true, "push after a hold is ignored")

-- Next hold reverses direction.
dali.Group1Level.Value = 60
shelly.Input1Held.Boolean = true; fire(shelly.Input1Held)
Q.advance(0.5)
ok(dali.Group1Lower.Boolean == true, "second hold lowers")
shelly.Input1Held.Boolean = false; fire(shelly.Input1Held)
ok(dali.Group1Lower.Boolean == false, "release stops lower")

-- Double press recalls the scene.
fire(shelly.Input1DoublePush)
ok(dali.Group1Scene.Value == 1 and dali.Group1Recall.triggers == 1, "double press recalls scene 1")

io.write(("meeting-room: %d checks passed\n"):format(pass))
