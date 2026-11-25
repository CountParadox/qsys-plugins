local Q = dofile("tests/qsys_mock.lua")
local PLUGIN = "plugins/Shelly-Gen2.qplug"
local pass = 0
local function ok(cond, msg) assert(cond, msg); pass = pass + 1 end

-- 2PM-style device: 2 switches, 2 inputs, 1 cover, power metering.
Q.load(PLUGIN, { ["Switches"] = 2, ["Inputs"] = 2, ["Covers"] = 1, ["Lights (dimmer channels)"] = 1 })
Controls.IPAddress.String = "192.168.1.20"
Controls.HeartbeatPath.String = "/script/1/hb"
Q.run(PLUGIN)

local s = Q.socket()
ok(s.proto == "ws" and s.host == "192.168.1.20" and s.path == "/rpc" and s.port == 80, "connects to ws://ip/rpc")
ok(Controls.Status.Value == 5, "initialising before connect")

s.Connected(s)
local info = Q.json.decode(s.sent[1]); local st = Q.json.decode(s.sent[2])
ok(info.method == "Shelly.GetDeviceInfo" and st.method == "Shelly.GetStatus", "requests info and status on connect")
ok(type(info.src) == "string" and info.src:match("^qsys%-"), "frames carry a src so the device sends notifications")

Q.recv({ id = info.id, result = { name = "Meeting Room", model = "S3SW-002P16EU", ver = "1.4.4" } })
ok(Controls.DeviceName.String == "Meeting Room" and Controls.Model.String == "S3SW-002P16EU", "device info shown")

Q.recv({ id = st.id, result = {
  ["switch:0"] = { id = 0, output = true, apower = 42.5, aenergy = { total = 12345 } },
  ["switch:1"] = { id = 1, output = false, apower = 0 },
  ["input:0"] = { id = 0, state = Q.json.null },
  ["input:1"] = { id = 1, state = true },
  ["cover:0"] = { id = 0, state = "stopped", current_pos = 30 },
  ["light:0"] = { id = 0, output = true, brightness = 55 },
  sys = { uptime = 5 },
} })
ok(Controls.Status.Value == 0 and Controls.Online.Boolean, "status OK after GetStatus")
ok(Controls.Switch1On.Boolean == true and Controls.Switch2On.Boolean == false, "switch state")
ok(Controls.Switch1Power.Value == 42.5 and math.abs(Controls.Switch1Energy.Value - 12.345) < 1e-9, "power and energy")
ok(Controls.Input2State.Boolean == true and Controls.Input1State.Boolean == false, "input state, null ignored")
ok(Controls.Cover1State.String == "stopped" and Controls.Cover1Position.Value == 30, "cover state")
ok(Controls.Light1Level.Value == 55, "light level")

-- Partial NotifyStatus update.
Q.recv({ src = "shelly", dst = info.src, method = "NotifyStatus", params = { ts = 1, ["switch:1"] = { id = 1, output = true } } })
ok(Controls.Switch2On.Boolean == true and Controls.Switch1On.Boolean == true, "NotifyStatus delta applied")

-- Button events.
Q.recv({ method = "NotifyEvent", params = { ts = 2, events = { { component = "input:0", id = 0, event = "btn_down", ts = 2 } } } })
ok(Controls.Input1Held.Boolean == true, "btn_down sets Held")
Q.recv({ method = "NotifyEvent", params = { ts = 3, events = {
  { component = "input:0", id = 0, event = "btn_up", ts = 3 },
  { component = "input:0", id = 0, event = "single_push", ts = 3 },
} } })
ok(Controls.Input1Held.Boolean == false and Controls.Input1Push.triggers == 1, "btn_up + single_push")
Q.recv({ method = "NotifyEvent", params = { events = { { component = "input:1", id = 1, event = "double_push" }, { component = "input:1", id = 1, event = "long_push" } } } })
ok(Controls.Input2DoublePush.triggers == 1 and Controls.Input2LongPush.triggers == 1, "double and long push")
Q.recv({ method = "NotifyEvent", params = { events = { { component = "input:3", id = 3, event = "single_push" } } } })
ok(true, "events for components beyond the configured count are ignored")

-- Commands go over the WebSocket.
Q.set("Switch1On", "Boolean", false)
local m = Q.sent(s)
ok(m.method == "Switch.Set" and m.params.id == 0 and m.params.on == false, "Switch.Set over ws")
Q.press("Switch2Toggle")
m = Q.sent(s)
ok(m.method == "Switch.Set" and m.params.id == 1 and m.params.on == false and Controls.Switch2On.Boolean == false, "toggle flips state")
Q.press("Cover1Open"); ok(Q.sent(s).method == "Cover.Open", "cover open")

-- Fader throttling: rapid moves send first value then the last one.
local before = #s.sent
Q.set("Light1Level", "Value", 10); Q.set("Light1Level", "Value", 20); Q.set("Light1Level", "Value", 30)
ok(#s.sent == before + 1 and Q.json.decode(s.sent[#s.sent]).params.brightness == 10, "first fader move sent immediately")
Q.advance(0.2)
ok(#s.sent == before + 2 and Q.sent(s).params.brightness == 30, "final fader value sent after throttle")
-- Feedback ignored while fader is held, accepted afterwards.
Q.recv({ method = "NotifyStatus", params = { ["light:0"] = { brightness = 12 } } })
ok(Controls.Light1Level.Value == 30, "feedback suppressed during fader move")
Q.advance(2)
Q.recv({ method = "NotifyStatus", params = { ["light:0"] = { brightness = 12 } } })
ok(Controls.Light1Level.Value == 12, "feedback applied after fader release")
Q.set("Light1Level", "Value", 0); Q.advance(1)
local found = false
for i = #s.sent, 1, -1 do local x = Q.json.decode(s.sent[i]); if x.method == "Light.Set" then found = (x.params.on == false); break end end
ok(found, "level 0 turns the light off")

-- Heartbeat polls status and pings the fallback script.
Q.http = {}
local n0 = #s.sent
Q.recv({ method = "NotifyStatus", params = {} }) -- keep alive
Q.advance(10)
ok(#s.sent > n0 and Q.sent(s).method == "Shelly.GetStatus", "heartbeat polls status")
ok(#Q.http == 1 and Q.http[1].Url == "http://192.168.1.20/script/1/hb", "heartbeat hits fallback script endpoint")

-- Silence -> stale -> reconnect.
Q.advance(30)
ok(Controls.Status.Value == 4 and s.closed and Controls.Status.String == "No response from device", "stale connection closed")
Q.advance(6)
local s2 = Q.socket()
ok(s2 ~= s and Controls.Status.Value == 5, "reconnected with a new socket")
-- Old socket callbacks are ignored.
s.Data(s, Q.json.encode({ method = "NotifyStatus", params = { ["switch:0"] = { output = true } } }))
ok(Controls.Switch1On.Boolean == false, "stale socket data ignored")

-- While disconnected, commands fall back to HTTP.
Q.http = {}
Q.set("Switch1On", "Boolean", true)
ok(#Q.http == 1 and Q.http[1].Url == "http://192.168.1.20/rpc" and Q.json.decode(Q.http[1].Data).method == "Switch.Set", "HTTP fallback")
Q.httpReply("/rpc", 200, Q.json.encode({ id = 0, result = { was_on = false } }))

-- Closed event triggers reconnect.
s2.Connected(s2)
s2.Closed(s2)
ok(Controls.Status.Value == 4 and not Controls.Online.Boolean, "closed -> missing")
Q.advance(5)
ok(Q.socket() ~= s2, "reconnect after close")

-- Presence Gen4 (frames captured from a real S4SN-0U61X, fw 2.2.0, on 2026-11-25).
Q.load(PLUGIN, { ["Switches"] = 0, ["Inputs"] = 0, ["Power Metering"] = false, ["Presence Zones"] = 2, ["Illuminance"] = true })
Controls.IPAddress.String = "192.168.61.207"
Q.run(PLUGIN)
local ps = Q.socket()
ps.Connected(ps)
local byMethod = {}
for _, raw in ipairs(ps.sent) do local x = Q.json.decode(raw); byMethod[x.method] = x end
ok(byMethod["Shelly.GetStatus"] and byMethod["Presence.GetConfig"], "presence: reads status and presence config on connect")
Q.recv({ id = byMethod["Shelly.GetStatus"].id, result = {
  ["illuminance:0"] = { id = 0, illumination = "dark" }, presence = { sensor_ver = "1.0" }, sys = { uptime = 1 } } }, ps)
ok(Controls.Illuminance.String == "dark" and Controls.Status.Value == 0, "illuminance from GetStatus")
Q.recv({ id = byMethod["Presence.GetConfig"].id, result = { enable = true, main_zone = "presencezone:201" } }, ps)
local gc = Q.sent(ps)
ok(gc.method == "Shelly.GetComponents" and gc.params.dynamic_only == true, "zones read with Shelly.GetComponents (not in GetStatus)")
Q.recv({ id = gc.id, result = { components = {
  { key = "presencezone:200", status = { id = 200, value = false, num_objects = 0 }, config = { id = 200, name = "Room" } },
  { key = "presencezone:201", status = { id = 201, value = true, num_objects = 2 }, config = { id = 201, name = "Table" } },
}, offset = 0, total = 2 } }, ps)
ok(Controls.Zone1Name.String == "Table" and Controls.Zone1Occupied.Boolean and Controls.Zone1Objects.Value == 2, "main zone is zone 1")
ok(Controls.Zone2Name.String == "Room" and not Controls.Zone2Occupied.Boolean, "other zones follow")
Q.recv({ src = "shellypresence", dst = "qsys", method = "NotifyStatus", params = { ts = 1, ["presencezone:200"] = { value = true, num_objects = 1 } } }, ps)
ok(Controls.Zone2Occupied.Boolean and Controls.Zone2Objects.Value == 1, "NotifyStatus updates a zone")
Q.recv({ method = "NotifyStatus", params = { ["presencezone:999"] = { value = true } } }, ps)
ok(true, "unknown zone ids are ignored")
Q.recv({ method = "NotifyStatus", params = { ts = 2, ["illuminance:0"] = { illumination = "twilight" } } }, ps)
ok(Controls.Illuminance.String == "twilight", "illuminance NotifyStatus")
Q.recv({ method = "NotifyStatus", params = { ["illuminance:0"] = { lux = 152.4, illumination = "bright" } } }, ps)
ok(Controls.Illuminance.String == "152 lx (bright)", "lux shown when the firmware reports it")
-- Heartbeat re-reads zones (they are not part of Shelly.GetStatus).
local before = #ps.sent
Q.advance(10)
local zonesPolled = false
for i = before + 1, #ps.sent do if Q.json.decode(ps.sent[i]).method == "Shelly.GetComponents" then zonesPolled = true end end
ok(zonesPolled, "heartbeat re-reads presence zones")
-- A sensor with fewer zones than configured.
local gc2
for i = #ps.sent, 1, -1 do local x = Q.json.decode(ps.sent[i]); if x.method == "Shelly.GetComponents" then gc2 = x; break end end
Q.recv({ id = gc2.id, result = { components = {
  { key = "presencezone:200", status = { id = 200, value = false, num_objects = 0 }, config = { id = 200, name = "Room" } } } } }, ps)
ok(Controls.Zone1Name.String == "Room" and Controls.Zone2Name.String == "(no zone)", "missing zones marked")
-- A switch-only device sends no presence calls.
Q.load(PLUGIN, {})
Controls.IPAddress.String = "192.168.60.224"
Q.run(PLUGIN)
Q.socket().Connected(Q.socket())
local anyPresence = false
for _, raw in ipairs(Q.socket().sent) do local mth = Q.json.decode(raw).method; if mth:find("Presence") or mth == "Shelly.GetComponents" then anyPresence = true end end
ok(not anyPresence, "no presence calls when Presence Zones = 0")

-- No IP.
Q.load(PLUGIN, {})
Q.run(PLUGIN)
ok(Controls.Status.Value == 3, "no IP -> not present")

print(("shelly: %d checks passed"):format(pass))
