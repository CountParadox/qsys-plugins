local Q = dofile("tests/qsys_mock.lua")
local PLUGIN = "plugins/Lunatone-DALI2-IoT.qplug"
local J = Q.json
local pass = 0
local function ok(cond, msg) assert(cond, msg); pass = pass + 1 end

-------------------------------------------------------------------------------
-- Fake DALI bus behind a fake gateway. Gateway frame formats copied from a SmartCore
-- (Atios, DALI-2 IoT protocol 3.0, fw 3.2.64) captured on 2026-11-25. Gear behaviour per
-- IEC 62386-102 / -207 (DT6) / -208 (DT7) / -209 (DT8).
-------------------------------------------------------------------------------
local bus, dtr, enabledDT = {}, { 0, 0, 0 }, nil
local function resetBus()
  local d4i = { 6, 50, 51, 52 } -- what every fitting on site reports (DT6 LED + D4i parts)
  bus = {
    [3]  = { groups = { [2] = true }, arc = 0, types = d4i },
    [26] = { groups = { [4] = true }, arc = 254, types = d4i, scenes = { [5] = 120 } },
    [27] = { groups = { [4] = true }, arc = 254, types = d4i, scenes = { [5] = 120 } },
    [28] = { groups = { [4] = true, [7] = true }, arc = 254, types = d4i, scenes = { [5] = 120 } },
    [30] = { groups = { [8] = true }, arc = 200, types = { 8 }, colour = { features = 0x02, tc = 300, rgbw = {} } },
    [31] = { groups = { [8] = true }, arc = 200, types = { 8 }, colour = { features = 0x02, tc = 300, rgbw = {} } },
    [32] = { groups = { [9] = true }, arc = 254, types = { 8 }, colour = { features = 4 << 5, rgbw = { 254, 0, 0, 0 } } },
    [40] = { groups = {}, arc = 0, types = { 7 } }, -- relay module, not in any group
  }
  dtr, enabledDT = { 0, 0, 0 }, nil
end
resetBus()
local log = {}       -- every daliData pair the plugin sent, in order
local silent = false -- when true the gateway never replies (timeout test)
local processed = 0

local function targets(a)
  local list = {}
  if a == 0xFE or a == 0xFF then for k, d in pairs(bus) do list[k] = d end
  elseif a & 0x80 == 0x80 and a < 0xA0 then
    local g = (a >> 1) & 0x0F
    for k, d in pairs(bus) do if d.groups[g] then list[k] = d end end
  elseif a & 0x80 == 0 then
    local d = bus[a >> 1]; if d then list[a >> 1] = d end
  end
  return list
end

local function has(t, x) for _, v in ipairs(t) do if v == x then return true end end return false end

local function gear(d, b)
  -- returns an answer byte or nil
  if b >= 0xE0 then
    if enabledDT ~= 8 or not has(d.types, 8) then return nil end -- extended commands need ENABLE DT 8
    local c = d.colour
    c.temp = c.temp or {}
    local t = c.temp
    if b == 0xE7 then t.tc = dtr[2] * 256 + dtr[1]
    elseif b == 0xEB then for k = 1, 3 do if dtr[k] ~= 255 then t["c" .. k] = dtr[k] end end
    elseif b == 0xEC then if dtr[1] ~= 255 then t.c4 = dtr[1] end
    elseif b == 0xE2 then
      if t.tc then c.tc = t.tc end
      for k = 1, 4 do if t["c" .. k] then c.rgbw[k] = t["c" .. k] end end
      c.temp = {}
    elseif b == 0xF9 then return c.features
    elseif b == 0xFA then
      local sel = dtr[1]
      if sel == 2 then
        if not c.tc then dtr[1] = 255; return 255 end
        dtr[1] = c.tc & 0xFF; return c.tc >> 8 -- MSB answered, LSB left in DTR0
      elseif sel >= 9 and sel <= 12 then return c.rgbw[sel - 8] or 255 end
      return 255
    end
    return nil
  end
  if b == 0x00 then d.arc = 0
  elseif b >= 0x10 and b <= 0x1F then d.arc = (d.scenes or {})[b - 0x10] or d.arc
  elseif b == 0x90 then return (d.status or 0) | ((d.arc > 0) and 4 or 0)
  elseif b == 0x98 then return dtr[1]
  elseif b == 0x99 then d.nextIdx = 1; return #d.types == 1 and d.types[1] or 255
  elseif b == 0xA7 then
    -- Real gear (captured on site): if the previous bus frame was not QUERY DEVICE TYPE /
    -- NEXT DEVICE TYPE to this gear, the list restarts from the first type.
    if not d.listing then d.nextIdx = 1 end
    local t = d.types[d.nextIdx or 1]
    d.nextIdx = (d.nextIdx or 1) + 1
    return t or 254
  elseif b == 0xA0 then return d.arc
  elseif b == 0xC0 or b == 0xC1 then
    local base, bits = (b == 0xC0) and 0 or 8, 0
    for g in pairs(d.groups) do if g >= base and g < base + 8 then bits = bits | (1 << (g - base)) end end
    return bits
  end
  return nil
end

local function handle(frame)
  local a, b = frame.daliData[1], frame.daliData[2]
  log[#log + 1] = { a, b }
  if silent then return end
  local s = Q.socket()
  local answer = nil
  local special = (a >= 0xA1 and a <= 0xCB and a & 1 == 1)
  if special then
    if a == 0xA3 then dtr[1] = b elseif a == 0xC3 then dtr[2] = b elseif a == 0xC5 then dtr[3] = b end
    enabledDT = (a == 0xC1) and b or nil
  else
    if a & 1 == 0 then
      for _, d in pairs(targets(a)) do d.arc = b end -- DAPC
    else
      for _, d in pairs(targets(a)) do local v = gear(d, b); if v ~= nil then answer = v end end
    end
    enabledDT = nil
  end
  -- Track whether each gear's device-type listing is still uninterrupted.
  for k, d in pairs(bus) do
    d.listing = (a == (k << 1) + 1) and (b == 0x99 or b == 0xA7)
  end
  Q.recv({ type = "daliMonitor", data = { line = 0, bits = 16, externalSource = false, query = frame.mode.waitForAnswer, data = { a, b } } }, s)
  Q.recv({ type = "daliFrame", data = { line = 0, result = 0 } }, s)
  if frame.mode.waitForAnswer then
    if answer then
      Q.recv({ type = "daliAnswer", data = { line = 0, result = 8, daliData = answer, queryData = { a, b }, queryBits = 16 } }, s)
    else
      Q.recv({ type = "daliAnswer", data = { line = 0, result = 0, queryData = { a, b }, queryBits = 16 } }, s)
    end
  end
end

-- Answer everything the plugin has sent (replies make it send more, so loop).
local function pump()
  local s = Q.socket()
  while processed < #s.sent do
    processed = processed + 1
    local msg = J.decode(s.sent[processed])
    assert(msg.type == "daliFrame", "unexpected message type " .. tostring(msg.type))
    assert(msg.data.line == 0 and msg.data.numberOfBits == 16, "frame header")
    handle(msg.data)
  end
end
-- Advance time in 50 ms slices, answering frames as they go (the real gateway replies in ~80 ms).
local function settle(seconds)
  pump()
  local left = seconds or 0
  local n = math.floor(left / 0.05 + 0.5)
  for _ = 1, n do Q.advance(0.05); pump() end
  if left - n * 0.05 > 1e-9 then Q.advance(left - n * 0.05); pump() end
end
local function sentSince(mark)
  local out = {}
  for i = mark + 1, #log do out[#out + 1] = log[i] end
  return out
end
local function sent(list, a, b)
  for _, f in ipairs(list) do if f[1] == a and f[2] == b then return true end end
  return false
end
local function seqIn(list, want)
  for s = 1, #list - #want + 1 do
    local m = true
    for k, w in ipairs(want) do if list[s + k - 1][1] ~= w[1] or list[s + k - 1][2] ~= w[2] then m = false; break end end
    if m then return true end
  end
  return false
end
-- Every ENABLE DEVICE TYPE must be followed directly by the extended command it enables.
local function checkEnable()
  for k, f in ipairs(log) do
    if f[1] == 0xC1 then
      local nx = log[k + 1]
      assert(nx, "ENABLE DT is the last frame")
      local addressedCmd = (nx[1] < 0xA0 and nx[1] & 1 == 1) or nx[1] == 0xFF
      assert(addressedCmd and nx[2] >= 0xE0, ("ENABLE DT followed by %d,%d"):format(nx[1], nx[2]))
    end
  end
  return true
end

-------------------------------------------------------------------------------
Q.load(PLUGIN, { ["Rows"] = 6, ["Colour Control"] = "Tunable White + RGBW" })
Controls.IPAddress.String = "192.168.60.14"
Controls.Group1Address.String = "4"   -- plain number = group (as in v0.2)
Controls.Group3Address.String = "G7"
Controls.Group4Address.String = "A40" -- relay by short address
Controls.Group5Address.String = "G8"  -- DT8 Tc
Controls.Group6Address.String = "A32" -- DT8 RGBW
Q.run(PLUGIN)

-- Pure helpers.
ok(PercentToArc(100) == 254 and PercentToArc(50) == 229 and PercentToArc(0) == 0 and PercentToArc(1) == 85, "percent -> arc (log curve)")
ok(ArcToPercent(254) == 100 and ArcToPercent(229) == 51 and ArcToPercent(2) == 0.1 and ArcToPercent(0) == 0, "arc -> percent")
for p = 1, 100 do assert(math.abs(ArcToPercent(PercentToArc(p)) - p) <= p * 0.03 + 0.1, "round trip " .. p) end
ok(true, "percent round trip within one DALI step")
local function addr(x) local t = ParseAddress(x); return t and (t.kind .. (t.n or "")) or "nil" end
ok(addr("4") == "group4" and addr("g15") == "group15" and addr("A26") == "short26" and addr(" s0 ") == "short0"
  and addr("BC") == "bc" and addr("G16") == "nil" and addr("A64") == "nil" and addr("x") == "nil", "address parsing")
ok(Controls.Group2Address.String == "G1", "empty rows default to G0, G1, ..")

local s = Q.socket()
ok(s.proto == "ws" and s.host == "192.168.60.14" and s.path == "/" and s.port == 80, "connects to ws://ip/")
s.Connected(s)
Q.recv({ type = "info", data = { name = "dali-iot", version = "3.2.64-beta/1.0.0", lines = { ["0"] = { lineStatus = "ok" } } } })
ok(Controls.GatewayName.String == "dali-iot" and Controls.Firmware.String == "3.2.64-beta/1.0.0", "gateway info from ws info message")
ok(Controls.Status.String == "Scanning DALI bus", "scanning on connect")
settle(0.1)

-- Scan results.
ok(Controls.Status.Value == 0, "status OK after scan")
ok(Controls.DeviceCount.String == "8", "eight fittings found")
ok(Controls.BusTypes.String == "4x DT6, 1x DT8 RGBW, 2x DT8 Tc, 1x Relay", "bus type summary: " .. Controls.BusTypes.String)
ok(Controls.Group1Members.String == "3" and Controls.Group1Types.String == "3x DT6", "group 4: 3x DT6 (multi-type D4i gear via QUERY NEXT DEVICE TYPE)")
ok(Controls.Group1On.Boolean and Controls.Group1Level.Value == 100, "group 4 on at 100%")
ok(Controls.Group3Members.String == "1", "fitting in several groups")
ok(Controls.Group4Types.String == "1x Relay" and not Controls.Group4On.Boolean, "relay row by short address")
ok(Controls.Group5Types.String == "2x DT8 Tc", "DT8 Tc group")
ok(Controls.Group6Types.String == "1x DT8 RGBW", "DT8 RGBW fitting")
ok(Controls.Group5Kelvin.Value == 3333, "Tc read back after scan (300 mirek = 3333 K), got " .. Controls.Group5Kelvin.Value)
ok(Controls.Group6Red.Value == 100 and Controls.Group6Green.Value == 0, "RGBW read back after scan")
ok(not Controls.Group1Fault.Boolean and Controls.Group1FaultText.String == "", "no faults")
local q = 0
for _, f in ipairs(log) do if f[2] == 0xA0 and f[1] < 0x80 then q = q + 1 end end
ok(q >= 64, "scan queries all 64 short addresses")
ok(checkEnable(), "ENABLE DEVICE TYPE always directly precedes its extended command (scan)")
local nexts = {}
for k, f in ipairs(log) do
  if f[2] == 0xA7 then
    local prev = log[k - 1]
    assert(prev[1] == f[1] and (prev[2] == 0x99 or prev[2] == 0xA7), "QUERY NEXT DEVICE TYPE not directly after QUERY DEVICE TYPE / NEXT")
    nexts[f[1]] = (nexts[f[1]] or 0) + 1
  end
end
ok(nexts[53] == 5 and nexts[61] == nil, "device types listed in one uninterrupted sequence (4 types + end), none for single-type gear")

-- DT6 group: off / level / on.
local m = #log
Q.set("Group1On", "Boolean", false); settle(0)
ok(sentSince(m)[1][1] == 0x89 and sentSince(m)[1][2] == 0x00, "Off = OFF to group 4 (0x89 0x00)")
ok(bus[26].arc == 0 and bus[28].arc == 0 and bus[3].arc == 0 and bus[30].arc == 200, "only group 4 switched")
settle(4)
ok(not Controls.Group1On.Boolean and Controls.Group1Level.Value == 0, "feedback after off")
m = #log
Q.set("Group1Level", "Value", 50); settle(0)
ok(sentSince(m)[1][1] == 0x88 and sentSince(m)[1][2] == 229, "50% = DAPC 229 to group 4")
settle(4)
ok(Controls.Group1On.Boolean and Controls.Group1Level.Value == 50, "level feedback")
Q.set("Group1On", "Boolean", false); settle(4)
m = #log
Q.set("Group1On", "Boolean", true); settle(0)
ok(sent(sentSince(m), 0x88, 229), "On restores the last level")
settle(4)

-- Fader throttling.
m = #log
Q.set("Group1Level", "Value", 10); Q.set("Group1Level", "Value", 20); Q.set("Group1Level", "Value", 30)
settle(0)
local dapc = {}
for _, f in ipairs(sentSince(m)) do if f[1] == 0x88 then dapc[#dapc + 1] = f[2] end end
ok(#dapc == 1 and dapc[1] == PercentToArc(10), "first fader move sent at once")
settle(0.25)
dapc = {}
for _, f in ipairs(sentSince(m)) do if f[1] == 0x88 then dapc[#dapc + 1] = f[2] end end
ok(#dapc == 2 and dapc[2] == PercentToArc(30), "final fader value sent after throttle")
bus[26].arc, bus[27].arc, bus[28].arc = 200, 200, 200
settle(0.5)
ok(Controls.Group1Level.Value == 30, "feedback suppressed while moving")
settle(4)
ok(Controls.Group1Level.Value == ArcToPercent(200), "feedback applied after release")

-- Scene.
m = #log
Controls.Group1Scene.Value = 5
Q.press("Group1Recall"); settle(3)
ok(sent(sentSince(m), 0x89, 0x15), "scene 5 = GO TO SCENE (0x89 0x15)")
ok(Controls.Group1Level.Value == ArcToPercent(120), "level read back after scene")

-- Relay (DT7) by short address 40.
m = #log
Q.set("Group4On", "Boolean", true); settle(0)
ok(sentSince(m)[1][1] == 80 and sentSince(m)[1][2] == 254, "relay on = DAPC 254 to short address 40")
ok(bus[40].arc == 254 and bus[26].arc == 120, "only the relay switched")
settle(4)
ok(Controls.Group4On.Boolean, "relay on feedback")
m = #log
Q.set("Group4On", "Boolean", false); settle(4)
ok(sent(sentSince(m), 81, 0x00) and bus[40].arc == 0 and not Controls.Group4On.Boolean, "relay off = OFF to short address 40")

-- DT8 Tc: 4000 K = 250 mirek.
m = #log
Q.set("Group5Kelvin", "Value", 4000); settle(0)
ok(seqIn(sentSince(m), { { 0xA3, 250 }, { 0xC3, 0 }, { 0xC1, 8 }, { 0x91, 0xE7 }, { 0xC1, 8 }, { 0x91, 0xE2 } }), "Tc sequence to group 8")
ok(bus[30].colour.tc == 250 and bus[31].colour.tc == 250, "Tc activated on the DT8 gear")
ok(bus[26].colour == nil, "DT6 gear unaffected")
settle(4)
ok(Controls.Group5Kelvin.Value == 4000, "Tc feedback")
bus[30].colour.tc, bus[31].colour.tc = 370, 370 -- changed elsewhere
settle(31)
ok(Controls.Group5Kelvin.Value == 2703, "external Tc change read back by the 30 s colour poll (got " .. Controls.Group5Kelvin.Value .. ")")

-- DT8 RGBW.
m = #log
Controls.Group6Red.Value = 0
Controls.Group6Blue.Value = 100
Q.set("Group6Green", "Value", 50); settle(0)
local seq = sentSince(m)
ok(seqIn(seq, { { 0xA3, 0 }, { 0xC3, 127 }, { 0xC5, 254 }, { 0xC1, 8 }, { 65, 0xEB } }), "SET TEMPORARY RGB DIMLEVEL (DTR0-2 = R,G,B)")
ok(seqIn(seq, { { 0xA3, 0 }, { 0xC3, 255 }, { 0xC5, 255 }, { 0xC1, 8 }, { 65, 0xEC }, { 0xC1, 8 }, { 65, 0xE2 } }), "WAF with amber/free unchanged, then ACTIVATE")
local rgbw = bus[32].colour.rgbw
ok(rgbw[1] == 0 and rgbw[2] == 127 and rgbw[3] == 254 and rgbw[4] == 0, "RGBW applied")
settle(4)
ok(Controls.Group6Green.Value == 50 and Controls.Group6Blue.Value == 100, "RGBW feedback")
ok(checkEnable(), "ENABLE DEVICE TYPE never split from its command, with polling running")

-- Faults.
bus[27].status = 2 -- lamp failure
settle(60)
ok(Controls.Group1Fault.Boolean and Controls.Group1FaultText.String == "A27 lamp failure", "lamp failure reported: " .. Controls.Group1FaultText.String)
bus[27].status = nil
local gone = bus[26]
bus[26] = nil
settle(60)
ok(Controls.Group1FaultText.String == "A26 missing", "missing fitting reported: " .. Controls.Group1FaultText.String)
bus[26] = gone
settle(6)
ok(not Controls.Group1Fault.Boolean, "fault clears when the fitting answers again")

-- Changes made elsewhere are picked up by polling; external bus frames trigger a quick re-read.
bus[26].arc, bus[27].arc, bus[28].arc = 0, 0, 0
settle(5)
ok(not Controls.Group1On.Boolean, "external change picked up by the 5 s poll")
bus[26].arc = 254
Q.recv({ type = "daliMonitor", data = { line = 0, bits = 16, externalSource = true, query = false, data = { 0x88, 254 } } })
settle(0.5)
ok(Controls.Group1On.Boolean and Controls.Group1Level.Value == 100, "external bus frame -> quick re-read")

-- Broadcast.
m = #log
Q.press("AllOff"); settle(0)
ok(sent(sentSince(m), 0xFF, 0x00) and bus[3].arc == 0 and bus[40].arc == 0, "broadcast off")
settle(4)

-- Raise ramps 4% per step and stops on release.
Controls.Group1Level.Value = 50
Q.set("Group1Raise", "Boolean", true)
settle(1.01)
Q.set("Group1Raise", "Boolean", false)
settle(0.3)
ok(Controls.Group1Level.Value == 70 and bus[26].arc == PercentToArc(70), "raise ramps 4%/step (got " .. Controls.Group1Level.Value .. ")")
local n = #log
settle(1)
local after = 0
for _, f in ipairs(sentSince(n)) do if f[1] == 0x88 then after = after + 1 end end
ok(after == 0, "ramp stops on release")
settle(4)

-- Commands jump ahead of queued queries.
Q.press("Refresh")
silent = true
settle(0)
silent = false
m = #log
Q.set("Group1On", "Boolean", false)
settle(1.1)
ok(sentSince(m)[1][1] == 0x89 and sentSince(m)[1][2] == 0x00, "command sent before queued scan queries")
settle(1)
ok(Controls.DeviceCount.String == "8" and Controls.Status.Value == 0, "rescan completes")
settle(4)

-- No reply at all: frames time out and the queue keeps moving.
silent = true
m = #log
Q.set("Group1On", "Boolean", true); settle(0)
Controls.Group1Scene.Value = 2
Q.press("Group1Recall"); settle(0)
ok(#sentSince(m) == 1, "one frame in flight at a time")
settle(1.1)
ok(#sentSince(m) >= 2 and sentSince(m)[2][2] == 0x12, "next frame after timeout")
silent = false
settle(4)

-- Bad address.
m = #log
Controls.Group1Address.String = "x"
Q.set("Group1On", "Boolean", true); settle(0)
ok(#sentSince(m) == 0 and Controls.Status.Value == 1, "invalid address blocks command")
Controls.Group1Address.String = "G4"
settle(4)

-- WebSocket drop -> fault -> reconnect -> rescan.
s.Closed(s)
ok(Controls.Status.Value == 2 and not Controls.Online.Boolean, "ws closed -> fault")
Q.set("Group1On", "Boolean", false)
ok(#s.sent == processed, "nothing sent while disconnected")
Q.advance(5)
local s2 = Q.socket()
ok(s2 ~= s, "reconnect attempted")
processed = 0
s2.Connected(s2); settle(0.1)
ok(Controls.Status.Value == 0 and Controls.DeviceCount.String == "8", "rescanned after reconnect")
s.Data(s, J.encode({ type = "info", data = { name = "old", version = "x" } }))
ok(Controls.GatewayName.String == "dali-iot", "stale socket data ignored")
Q.recv({ type = "info", data = { name = "dali-iot", version = "3.2.64-beta/1.0.0", lines = { ["0"] = { lineStatus = "noPower" } } } }, s2)
ok(Controls.Status.Value == 1 and Controls.Status.String:find("noPower"), "DALI line fault shown")

-- Colour controls only when the property asks for them.
Q.load(PLUGIN, {})
ok(Controls.Group1Kelvin == nil and Controls.Group1Red == nil, "Colour Control = None: no colour faders")
Q.load(PLUGIN, { ["Colour Control"] = "Tunable White", ["Kelvin Min"] = 2200, ["Kelvin Max"] = 5000 })
ok(Controls.Group1Kelvin ~= nil and Controls.Group1Red == nil, "Tunable White: Kelvin only")

-- Empty bus.
Q.load(PLUGIN, {})
Controls.IPAddress.String = "192.168.60.14"
bus = {}
log, processed = {}, 0
Q.run(PLUGIN)
Q.socket().Connected(Q.socket()); settle(0.1)
ok(Controls.Status.Value == 1 and Controls.DeviceCount.String == "0", "no fittings -> warning")
resetBus()

-- No IP.
Q.load(PLUGIN, {})
Q.run(PLUGIN)
ok(Controls.Status.Value == 3, "no IP -> not present")

print(("dali: %d checks passed"):format(pass))
