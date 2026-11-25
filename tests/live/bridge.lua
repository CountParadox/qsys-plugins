-- Runs a plugin against real devices: the Q-SYS mock runtime, with WebSocket traffic
-- relayed over stdin/stdout by tests/live/bridge.py. Not part of the offline suite.
-- usage (via bridge.py): lua53 tests/live/bridge.lua <plugin> <ip> [Prop=value ...]

local Q = dofile("tests/qsys_mock.lua")
io.stdout:setvbuf("line")
local function out(...) io.stdout:write(table.concat({ ... }, " "), "\n"); io.stdout:flush() end -- Windows CRT treats "line" as full buffering
print = function(...) local t = {} for i, v in ipairs({ ... }) do t[i] = tostring(v) end out("LOG", table.concat(t, " ")) end

local socks, nextId = {}, 0
WebSocket = {}
function WebSocket.New()
  nextId = nextId + 1
  local s = { id = nextId }
  function s:Connect(proto, host, path, port) out("OPEN", self.id, host, tostring(port), path) end
  function s:Write(data) out("SEND", self.id, (data:gsub("\n", " "))) end
  function s:Close() out("CLOSE", self.id) end
  function s:Ping() end
  socks[s.id] = s
  return s
end
HttpClient = {
  Download = function(t) out("LOG", "HTTP GET (not bridged)", t.Url) end,
  Upload = function(t) out("LOG", "HTTP " .. (t.Method or "POST") .. " (not bridged)", t.Url) end,
}

local plugin, ip = arg[1], arg[2]
local props = {}
for i = 3, #arg do
  local k, v = arg[i]:match("^(.-)=(.*)$")
  if v == "true" then v = true elseif v == "false" then v = false else v = tonumber(v) or v end
  props[k] = v
end
local sets = {}
for k, v in pairs(props) do if k:sub(1, 1) == "@" then sets[k:sub(2)] = v; props[k] = nil end end
Q.load(plugin, props)
Controls.IPAddress.String = ip
for k, v in pairs(sets) do Controls[k].String = tostring(v) end
Q.run(plugin)

local function dump()
  local names = {}
  for name in pairs(Controls) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local c = Controls[name]
    out("CTL", name, "value=" .. tostring(c.Value), "string=" .. tostring(c.String))
  end
end

for line in io.lines() do
  local cmd, id, rest = line:match("^(%S+)%s*(%d*)%s?(.*)$")
  local s = socks[tonumber(id or "")]
  if cmd == "TICK" then Q.advance(tonumber(rest) or 0.05)
  elseif cmd == "CONNECTED" and s then s.Connected(s)
  elseif cmd == "DATA" and s then s.Data(s, rest)
  elseif cmd == "CLOSED" and s and s.Closed then s.Closed(s)
  elseif cmd == "SET" then
    local name, field, value = rest:match("^(%S+) (%S+) (.*)$")
    Q.set(name, field, field == "Boolean" and (value == "true") or (tonumber(value) or value))
  elseif cmd == "PRESS" then Q.press(rest)
  elseif cmd == "DUMP" then dump()
  elseif cmd == "QUIT" then break end
end
