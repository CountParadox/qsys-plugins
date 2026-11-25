local Q = dofile("tests/qsys_mock.lua")
local PLUGIN = "plugins/Lunatone-DALI2-IoT.qplug"
local J = Q.json
local pass = 0
local function ok(cond, msg) assert(cond, msg); pass = pass + 1 end

Q.load(PLUGIN, { ["Group Rows"] = 3, ["Tunable White"] = true })
Controls.IPAddress.String = "192.168.1.60"
Controls.Group3Address.String = "7"
Q.run(PLUGIN)

ok(Controls.Group1Address.String == "0" and Controls.Group2Address.String == "1", "empty group rows default to 0,1,..")
ok(Controls.Group3Address.String == "7", "configured group number kept")

local s = Q.socket()
ok(s.proto == "ws" and s.host == "192.168.1.60" and s.path == "/" and s.port == 80, "connects to ws://ip/")
s.Connected(s)
local filt = J.decode(s.sent[1])
ok(filt.type == "filtering" and filt.data.daliMonitor == true, "filters bus monitor traffic")

local function dev(id, groups, on, level, k)
  return { id = id, name = "DALI #" .. id, address = id, line = 0, groups = groups,
    features = { switchable = { status = on }, dimmable = { status = level }, colorKelvin = k and { status = k } or nil } }
end

Q.httpReply("/info$", 200, J.encode({ name = "atios", version = "v1.17.0" }))
Q.httpReply("/devices$", 200, J.encode({ devices = {
  dev(1, { 0 }, true, 80, 3000), dev(2, { 0 }, true, 40, 3000), dev(3, { 1 }, false, 0), dev(4, { 7, 1 }, false, 0),
} }))
ok(Controls.Status.Value == 0, "status OK")
ok(Controls.GatewayName.String == "atios" and Controls.Firmware.String == "v1.17.0", "gateway info")
ok(Controls.DeviceCount.String == "4", "device count")
ok(Controls.Group1Members.String == "2" and Controls.Group1On.Boolean and Controls.Group1Level.Value == 80, "group 0 derived state")
ok(Controls.Group1Kelvin.Value == 3000, "group kelvin")
ok(Controls.Group2Members.String == "2" and not Controls.Group2On.Boolean and Controls.Group2Level.Value == 0, "group 1 off")
ok(Controls.Group3Members.String == "1", "group 7 membership")

-- Partial websocket update: device 3 turned on at 60%.
Q.recv({ type = "devices", data = { devices = { { id = 3, features = { switchable = { status = true }, dimmable = { status = 60 } } } } } })
ok(Controls.Group2On.Boolean and Controls.Group2Level.Value == 60, "ws partial update merged")
-- group membership change keeps other fields
Q.recv({ type = "devices", data = { devices = { { id = 3, groups = { 1, 7 } } } } })
ok(Controls.Group3Members.String == "2" and Controls.Group2Level.Value == 60, "groups array replaced, features kept")

-- Commands.
Q.http = {}
Q.set("Group1On", "Boolean", false)
local r = Q.http[1]
ok(r.Url == "http://192.168.1.60/group/0/control" and r.kind == "POST" and J.decode(r.Data).switchable == false, "group off")
Q.httpReply("/group/0/control", 200, "")
ok(Controls.Status.Value == 0, "status stays OK after successful command")

Q.http = {}
Controls.Group3Scene.Value = 5
Q.press("Group3Recall")
ok(Q.http[1].Url:find("/group/7/control$") and J.decode(Q.http[1].Data).scene == 5, "scene recall to group 7")
Q.httpReply("/group/7/control", 200, "")

Q.http = {}
Q.set("Group2Level", "Value", 30); Q.set("Group2Level", "Value", 45)
ok(#Q.http == 1 and J.decode(Q.http[1].Data).dimmable == 30, "level sent immediately")
Q.advance(0.25)
ok(#Q.http == 2 and J.decode(Q.http[2].Data).dimmable == 45, "final level sent after throttle")
-- feedback suppressed during move
Q.recv({ type = "devices", data = { devices = { { id = 3, features = { dimmable = { status = 31 } } } } } })
ok(Controls.Group2Level.Value == 45, "feedback suppressed while moving")
Q.advance(3)

-- Raise ramps.
Q.http = {}
Controls.Group1Level.Value = 50
Q.set("Group1Raise", "Boolean", true)
Q.advance(1.0)
Q.set("Group1Raise", "Boolean", false)
local last = J.decode(Q.http[#Q.http].Data).dimmable
ok(Controls.Group1Level.Value == 70 and last == 70, "raise ramps 4%/step and sends final level (got " .. tostring(last) .. ")")
local count = #Q.http
Q.advance(2)
ok(#Q.http == count, "ramp stops on release")

-- Kelvin.
Q.http = {}
Q.set("Group1Kelvin", "Value", 4000)
ok(J.decode(Q.http[1].Data).colorKelvin == 4000, "colour temperature")

-- Broadcast.
Q.http = {}
Q.press("AllOff")
ok(Q.http[1].Url:find("/broadcast/control$") and J.decode(Q.http[1].Data).switchable == false, "broadcast off")

-- Failed command flags the status.
Q.httpReply("/broadcast/control", 500, "")
ok(Controls.Status.Value == 1, "failed command -> compromised")

-- Bad group number.
Q.http = {}
Controls.Group1Address.String = "x"
Q.set("Group1On", "Boolean", true)
ok(#Q.http == 0 and Controls.Status.Value == 1, "invalid group number blocks command")

-- WebSocket drop -> polling -> reconnect.
Controls.Group1Address.String = "0"
s.Closed(s)
ok(Controls.Status.Value == 1, "ws closed -> compromised, polling")
Q.http = {}
Q.advance(5)
ok(Q.socket() ~= s, "reconnect attempted")
Q.advance(6)
local polled = false
for _, x in ipairs(Q.http) do if x.Url:find("/devices$") then polled = true end end
ok(polled, "polls /devices while ws is down")

print(("dali: %d checks passed"):format(pass))
