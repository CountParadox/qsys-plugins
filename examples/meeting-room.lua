--[[
Meeting room lighting logic (pilot)

Paste into a Control Script / Text Controller in the Q-SYS design.
Set "Script Access" to "Script" (or "All") on the components named below.

Wall switch (Shelly SW input, set to "Button" and "Detached" in the Shelly UI):
  single press   -> toggle the DALI group
  double press   -> recall the "presentation" scene
  press and hold -> dim; each new hold reverses direction (up after off/low, down otherwise)

The UCI can use the DALI plugin's group controls (On, Level, Scene/Recall) directly;
this script only adds the wall-switch behaviour.
]]

-- Configuration ----------------------------------------------------------------
local SHELLY_NAME     = "Shelly Meeting Room Switch" -- Shelly Gen2+ plugin with the wall switch
local SHELLY_INPUT    = 1                            -- which input on that Shelly (1-based)
local DALI_NAME       = "SmartCore DALI"             -- Atios SmartCore DALI plugin
local DALI_ROW        = 1                            -- group row in the DALI plugin for this room
local SCENE_DOUBLE    = 1                            -- DALI scene for double press
local HOLD_DELAY_S    = 0.4                          -- hold this long before dimming starts
---------------------------------------------------------------------------------

local shelly = Component.New(SHELLY_NAME)
local dali = Component.New(DALI_NAME)

local inp = "Input" .. SHELLY_INPUT
local grp = "Group" .. DALI_ROW

local holdTimer = Timer.New()
local dimming = false
local lastDir = -1
local suppressPush = false

local function stopDim()
  holdTimer:Stop()
  if dimming then
    dali[grp .. "Raise"].Boolean = false
    dali[grp .. "Lower"].Boolean = false
    dimming = false
  end
end

holdTimer.EventHandler = function()
  holdTimer:Stop()
  -- Start dimming. Reverse direction on each hold, but always go up from off or very low.
  local level = dali[grp .. "Level"].Value
  local dir = -lastDir
  if not dali[grp .. "On"].Boolean or level < 5 then dir = 1 end
  if level >= 99 then dir = -1 end
  lastDir = dir
  dimming = true
  suppressPush = true -- the release that ends a hold must not also toggle
  dali[dir > 0 and (grp .. "Raise") or (grp .. "Lower")].Boolean = true
end

shelly[inp .. "Held"].EventHandler = function(c)
  if c.Boolean then
    suppressPush = false
    holdTimer:Start(HOLD_DELAY_S)
  else
    stopDim()
  end
end

shelly[inp .. "Push"].EventHandler = function()
  if suppressPush then suppressPush = false return end
  local on = dali[grp .. "On"]
  on.Boolean = not on.Boolean
end

shelly[inp .. "DoublePush"].EventHandler = function()
  dali[grp .. "Scene"].Value = SCENE_DOUBLE
  dali[grp .. "Recall"]:Trigger()
end

-- Long press is handled by the hold logic above.
shelly[inp .. "LongPush"].EventHandler = function() suppressPush = true end

print("Meeting room lighting logic running")
