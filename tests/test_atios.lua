-- Atios SmartCore DALI plugin against a fake SmartCore.
local Q = dofile("tests/qsys_mock.lua")
local PLUGIN = "plugins/Atios-SmartCore-DALI.qplug"
local J = Q.json
local pass = 0
local function ok(cond, msg) assert(cond, msg); pass = pass + 1 end

-- Fake SmartCore ----------------------------------------------------------------
local SC = {
  settings = { dali_ip_interface = true },
  levels = { [0] = 0, [1] = 0, [2] = 120 }, -- QUERY ACTUAL LEVEL answers by short address
  sent = {},                                -- frames received on /api/dali/iface
  leaseCode = 200,
}
local NVM = {
  { is_group = true, name = "Meeting Room", address = 129 },
  { is_group = false, name = "MR Downlight 1", address = 0, gear_groups = { 1 }, min_level = 1, max_level = 254, fade_rate = 7,
    gear_scenes = { { number = 1, enabled = true, level = 200 }, { number = 2, enabled = false, level = 10 } } },
  { is_group = false, name = "MR Downlight 2", address = 1, gear_groups = { 1 }, min_level = 1, max_level = 254, fade_rate = 7 },
  { is_group = false, name = "Collision", address = 63, collision = true },
  { is_group = false, name = "Hall", address = 2, gear_groups = { 0 }, min_level = 1, max_level = 254 },
  { is_group = true, name = "Hall", address = 128 },
}

local function serve()
  local guard = 0
  while #Q.http > 0 do
    guard = guard + 1; assert(guard < 500, "http loop")
    local r = Q.http[1]
    local url = r.Url
    if url:find("/ota_status$") then
      Q.httpReply("/ota_status", 200, J.encode({ version_string = "3.2.64", serial = "ABC" }))
    elseif url:find("/settings$") then
      Q.httpReply("/settings", 200, J.encode(SC.settings))
    elseif url:find("/api/dali/nvm") then
      local offset = tonumber(url:match("offset=(%d+)"))
      local page = {}
      for i = offset + 1, math.min(offset + 4, #NVM) do page[#page + 1] = NVM[i] end
      Q.httpReply("/api/dali/nvm", 200, J.encode({ success = true, data = { control_devices = page },
        pagination = { offset = offset, limit = 4, total = #NVM, has_more = offset + 4 < #NVM } }))
    elseif url:find("/api/dali/iface$") then
      local body = J.decode(r.Data)
      SC.sent[#SC.sent + 1] = body
      if body.wait_response and body.data[2] == 0xA0 then
        local lvl = SC.levels[body.data[1] >> 1]
        Q.httpReply("/api/dali/iface", 200, J.encode({ success = lvl ~= nil, bus_busy = false, collision_detected = false, data = lvl or 0 }))
      else
        Q.httpReply("/api/dali/iface", 200, J.encode({ success = true }))
      end
    elseif url:find("/cmd/input_monitor_start$") then
      Q.httpReply("/cmd/input_monitor_start", SC.leaseCode, "")
    else
      error("unexpected url " .. url)
    end
  end
end

local function sock(path)
  for i = #Q.sockets, 1, -1 do if Q.sockets[i].path == path then return Q.sockets[i] end end
end
local function monitor(s, data, external)
  Q.recv({ type = "daliMonitor", data = { line = 0, bits = #data * 8, externalSource = external or false, data = data },
    timeSignature = { timestamp = 1, counter = 1 } }, s)
end
local function lastFrame(s)
  local m = J.decode(s.sent[#s.sent])
  assert(m.type == "daliFrame", "not a daliFrame")
  return m.data.daliData
end
local function eq(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

-- Start ---------------------------------------------------------------------------
Q.load(PLUGIN, { ["Group Rows"] = 2, ["Tunable White"] = true })
Controls.IPAddress.String = "10.0.0.5"
Q.run(PLUGIN)

ok(Controls.Group1Address.String == "0" and Controls.Group2Address.String == "1", "rows default to groups 0,1")
local ws, inws = sock("/"), sock("/ws")
ok(ws and ws.host == "10.0.0.5" and ws.port == 80, "DALI IP socket on ws://ip/")
ok(inws ~= nil, "input monitor socket on ws://ip/ws")

-- HTTP works before the socket is up: model and levels load.
serve()
ok(Controls.Firmware.String == "3.2.64", "firmware from /ota_status")
ok(Controls.DeviceCount.String == "3", "3 fittings (collision skipped), read across 2 NVRAM pages")
ok(Controls.Group2Name.String == "Meeting Room" and Controls.Group1Name.String == "Hall", "group names from NVRAM")
ok(Controls.Group2Members.String == "2" and Controls.Group1Members.String == "1", "membership")
ok(Controls.Group1On.Boolean and Controls.Group1Level.Value == 47, "hall level 120/254 = 47%")
ok(not Controls.Group2On.Boolean, "meeting room off")
ok(Controls.Status.Value == 1 and Controls.Status.String:find("over HTTP"), "HTTP-only status before the socket")

-- Socket greets -> live.
ws.Connected(ws)
inws.Connected(inws)
Q.recv({ type = "info", data = { name = "dali-iot", descriptor = { protocolVersion = "3.0" } } }, ws)
serve()
ok(Controls.Status.Value == 0 and Controls.LiveFeedback.Boolean, "greeted + IP interface on -> live (" .. Controls.Status.String .. ")")

-- Commands go out as daliFrame; state follows the echo, not the command.
local n = #ws.sent
Q.set("Group2On", "Boolean", true)
ok(eq(lastFrame(ws), { 0x83, 0x0A }), "On -> GO TO LAST ACTIVE LEVEL to group 1")
ok(#ws.sent == n + 1, "one frame")
SC.levels[0], SC.levels[1] = 180, 180 -- what the gear will report after going to its last level
monitor(ws, { 0x83, 0x0A })
Q.advance(2); serve()
ok(Controls.Group2On.Boolean and Controls.Group2Level.Value == 71, "unknown last level -> queried -> 180 = 71%")
local queried = 0
for _, f in ipairs(SC.sent) do if f.wait_response then queried = queried + 1 end end
ok(queried >= 5, "levels queried at start and after an ambiguous command (" .. queried .. ")")

Q.set("Group2Level", "Value", 50)
ok(eq(lastFrame(ws), { 0x82, 127 }), "Level 50% -> DAPC 127 to group 1")
monitor(ws, { 0x82, 127 })
Q.advance(3)
ok(Controls.Group2Level.Value == 50 and Controls.Group2On.Boolean, "DAPC echo applied")

Q.set("Group2Level", "Value", 0)
ok(eq(lastFrame(ws), { 0x83, 0x00 }), "Level 0 -> OFF")
monitor(ws, { 0x83, 0x00 })
Q.advance(3)
ok(not Controls.Group2On.Boolean and Controls.Group2Level.Value == 0, "OFF echo applied")

-- Scene recall: gear 0 has a stored level, gear 1 not -> query gear 1.
Controls.Group2Scene.Value = 1
Q.press("Group2Recall")
ok(eq(lastFrame(ws), { 0x83, 0x11 }), "recall scene 1 -> GO TO SCENE 1")
SC.sent = {}
SC.levels[1] = 90
monitor(ws, { 0x83, 0x11 })
ok(Controls.Group2Level.Value == math.floor(200 / 254 * 100 + 0.5), "scene level from NVRAM applied")
Q.advance(2); serve()
local q1 = false
for _, f in ipairs(SC.sent) do if f.wait_response and f.data[1] == 0x03 and f.data[2] == 0xA0 then q1 = true end end
ok(q1, "gear without a stored scene level is queried")

-- The SmartCore's own frames (e.g. its own accessories) also update the state.
monitor(ws, { 0x04, 254 }, false) -- DAPC to short address 2 (Hall)
ok(Controls.Group1Level.Value == 100, "frame from another master tracked")

-- Raise from off: ON AND STEP UP, then UP repeated while held.
monitor(ws, { 0x83, 0x00 })
Q.advance(3)
n = #ws.sent
Q.set("Group2Raise", "Boolean", true)
ok(eq(J.decode(ws.sent[n + 1]).data.daliData, { 0x83, 0x08 }) and eq(J.decode(ws.sent[n + 2]).data.daliData, { 0x83, 0x01 }), "raise from off: ON AND STEP UP + UP")
Q.advance(0.65)
ok(#ws.sent == n + 5, "UP repeated every 200 ms (" .. (#ws.sent - n) .. ")")
Q.set("Group2Raise", "Boolean", false)
local m = #ws.sent
Q.advance(1)
ok(#ws.sent == m, "release stops the ramp")
-- echo of UP moves the mirror by the fade-rate step
monitor(ws, { 0x83, 0x08 })
monitor(ws, { 0x83, 0x01 })
ok(Controls.Group2Level.Value > 0, "UP echo raises the level")

-- Colour temperature (DT8).
n = #ws.sent
Q.set("Group1Kelvin", "Value", 4000)
local seq = {}
for i = n + 1, #ws.sent do seq[#seq + 1] = J.decode(ws.sent[i]).data.daliData end
ok(#seq == 6 and eq(seq[1], { 0xA3, 250 }) and eq(seq[2], { 0xC3, 0 }) and eq(seq[3], { 0xC1, 8 })
  and eq(seq[4], { 0x81, 0xE7 }) and eq(seq[5], { 0xC1, 8 }) and eq(seq[6], { 0x81, 0xE2 }), "4000 K -> DT8 Tc 250 mired + activate")
Q.advance(3)

-- Broadcast.
Q.press("AllOff")
ok(eq(lastFrame(ws), { 0xFF, 0x00 }), "All Off -> broadcast OFF")
monitor(ws, { 0xFF, 0x00 })
ok(not Controls.Group1On.Boolean and not Controls.Group2On.Boolean, "broadcast OFF applied to all")

-- DALI-2 button event shows up for commissioning.
monitor(ws, { 0x0A, 0x84, 0x01 }, true)
ok(Controls.LastBusEvent.String == "A5 I1 pressed", "button event decoded: " .. Controls.LastBusEvent.String)

-- Bus scan pauses commands.
monitor(ws, { 0xFF, 0xFE, 0x1D })
ok(Controls.BusScan.Boolean and Controls.Status.Value == 1, "bus scan detected")
n = #ws.sent
Q.press("AllOn")
ok(#ws.sent == n, "commands paused during scan")
monitor(ws, { 0xFF, 0xFE, 0x1E })
ok(not Controls.BusScan.Boolean and Controls.Status.Value == 0, "scan ended")
Q.press("AllOn")
ok(eq(lastFrame(ws), { 0xFF, 0x05 }), "All On -> broadcast RECALL MAX")
monitor(ws, { 0xFF, 0x05 })

-- Built-in inputs.
Q.recv("x", inws) -- not JSON / not IN:, ignored
inws.Data(inws, "IN:3,1")
ok(Controls.Input4.Boolean, "IN:3,1 -> input 4 on")
inws.Data(inws, "IN:3,0")
ok(not Controls.Input4.Boolean, "IN:3,0 -> input 4 off")
inws.Data(inws, "IN:12,1")
ok(true, "out-of-range pin ignored")
SC.leaseCode = 401
Q.advance(10); serve()
ok(Controls.Status.String:find("web password"), "401 on the lease reported")
SC.leaseCode = 200
Q.advance(10); serve()

-- Stream taken over: a command is never echoed -> reconnect.
Q.press("AllOff")
Q.advance(20)
ok(ws.closed, "no echo for 15 s -> socket dropped")
ok(Controls.Status.String:find("stream lost") or Controls.Status.String:find("over HTTP"), "status explains: " .. Controls.Status.String)

-- While the socket is down, commands go over HTTP and the state follows our own commands.
SC.sent = {}
Q.set("Group2On", "Boolean", false)
serve()
local last = SC.sent[#SC.sent]
ok(last and eq(last.data, { 0x83, 0x00 }) and last.bits == 16 and last.wait_response == false, "HTTP fallback /api/dali/iface")
ok(not Controls.Group2On.Boolean, "state follows own command without stream")

-- Reconnect and greet again.
Q.advance(5)
local ws2 = sock("/")
ok(ws2 ~= ws, "reconnected")
ws2.Connected(ws2)
Q.recv({ type = "info", data = {} }, ws2)
serve()
monitor(ws2, { 0xFF, 0x00 })
ok(Controls.Status.Value == 0, "live again")

-- DALI IP Interface turned off: greeting but no monitor frames.
SC.settings.dali_ip_interface = false
ws2.Closed(ws2)
Q.advance(70)
local ws3 = sock("/")
ws3.Connected(ws3)
Q.recv({ type = "info", data = {} }, ws3)
serve()
ok(Controls.Status.Value == 1 and Controls.Status.String:find("DALI IP Interface"), "IP interface off reported")
n = #ws3.sent
Q.set("Group1On", "Boolean", true)
ok(#ws3.sent == n + 1, "commands still use the socket")

-- Firmware that never greets.
SC.settings.dali_ip_interface = true
ws3.Closed(ws3)
Q.advance(70)
local ws4 = sock("/")
ws4.Connected(ws4)
Q.advance(11); serve()
ok(Controls.Status.String:find("firmware"), "silent firmware reported: " .. Controls.Status.String)

-- SmartCore unreachable.
Q.load(PLUGIN, {})
Controls.IPAddress.String = "10.0.0.9"
Q.run(PLUGIN)
for _ = 1, 3 do local r = Q.http[1]; table.remove(Q.http, 1); r.EventHandler(r, 0, nil, "timeout", {}) end
ok(Controls.Status.Value == 2, "unreachable -> fault")

-- No IP.
Q.load(PLUGIN, {})
Q.run(PLUGIN)
ok(Controls.Status.Value == 3, "no IP -> not present")

print(("atios: %d checks passed"):format(pass))
