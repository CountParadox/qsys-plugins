-- Minimal mock of the Q-SYS Lua runtime, enough to load and exercise the plugins offline.
-- Usage: local Q = dofile("tests/qsys_mock.lua"); Q.load("plugins/X.qplug", { ["Prop"] = value })

local hasCjson, cjson = pcall(require, "cjson")
if not hasCjson then cjson = dofile("tests/json.lua") end

local Q = { http = {}, sockets = {}, timers = {}, clock = 1000, printed = {} }

package.preload["rapidjson"] = function()
  return { encode = cjson.encode, decode = cjson.decode, null = cjson.null }
end

os.time = function() return math.floor(Q.clock) end

-- Controls ------------------------------------------------------------------
local function newControl(def)
  local c = { _v = 0, _s = "", _def = def, triggers = 0 }
  local mt = {}
  mt.__index = function(t, k)
    if k == "Value" then return rawget(t, "_v")
    elseif k == "String" then return rawget(t, "_s")
    elseif k == "Boolean" then return rawget(t, "_v") ~= 0
    elseif k == "Trigger" then return function(self) self.triggers = self.triggers + 1 end
    end
  end
  mt.__newindex = function(t, k, v)
    if k == "Value" then
      rawset(t, "_v", v)
      if def.IndicatorType ~= "Status" then rawset(t, "_s", tostring(v)) end
    elseif k == "Boolean" then rawset(t, "_v", v and 1 or 0); rawset(t, "_s", v and "true" or "false")
    elseif k == "String" then rawset(t, "_s", v); local n = tonumber(v); if n and def.ControlType ~= "Text" then rawset(t, "_v", n) end
    else rawset(t, k, v) end
  end
  return setmetatable(c, mt)
end

-- Simulate a user (or a wired pin) changing a control: sets it and fires the EventHandler.
function Q.set(name, field, value)
  local c = Controls[name]
  assert(c, "no control " .. name)
  c[field] = value
  if c.EventHandler then c.EventHandler(c) end
end

function Q.press(name)
  local c = Controls[name]
  assert(c and c.EventHandler, "no handler on " .. name)
  c.EventHandler(c)
end

-- Timers --------------------------------------------------------------------
Timer = {}
function Timer.New()
  local t = { running = false, interval = 0, due = 0 }
  function t:Start(s) self.running = true; self.interval = s; self.due = Q.clock + s end
  function t:Stop() self.running = false end
  Q.timers[#Q.timers + 1] = t
  return t
end
function Timer.CallAfter(fn, s)
  local t = Timer.New(); t.EventHandler = function() t:Stop(); fn() end; t:Start(s)
end

-- Advance the mock clock, firing timers in order.
function Q.advance(seconds)
  local target = Q.clock + seconds
  while true do
    local nextT
    for _, t in ipairs(Q.timers) do
      if t.running and t.due <= target and (not nextT or t.due < nextT.due) then nextT = t end
    end
    if not nextT then break end
    Q.clock = nextT.due
    nextT.due = nextT.due + nextT.interval
    if nextT.EventHandler then nextT.EventHandler(nextT) end
  end
  Q.clock = target
end

-- HttpClient ----------------------------------------------------------------
HttpClient = {}
local function req(kind, t) t.kind = kind; Q.http[#Q.http + 1] = t end
function HttpClient.Download(t) req("GET", t) end
function HttpClient.Upload(t) req(t.Method or "POST", t) end

-- Reply to the oldest outstanding HTTP request matching urlPattern.
function Q.httpReply(urlPattern, code, body)
  for i, r in ipairs(Q.http) do
    if r.Url:find(urlPattern) then
      table.remove(Q.http, i)
      r.EventHandler(r, code, body, code == 200 and "" or "error", {})
      return r
    end
  end
  error("no pending http request matching " .. urlPattern)
end

-- WebSocket -----------------------------------------------------------------
WebSocket = {}
function WebSocket.New()
  local s = { sent = {}, open = false, closed = false }
  function s:Connect(proto, host, path, port) self.proto, self.host, self.path, self.port = proto, host, path, port end
  function s:Write(data) self.sent[#self.sent + 1] = data end
  function s:Close() self.closed = true end
  function s:Ping() self.pinged = (self.pinged or 0) + 1 end
  Q.sockets[#Q.sockets + 1] = s
  return s
end
function Q.socket() return Q.sockets[#Q.sockets] end
function Q.sent(s) s = s or Q.socket(); return cjson.decode(s.sent[#s.sent]) end
function Q.recv(obj, s) s = s or Q.socket(); s.Data(s, cjson.encode(obj)) end

-- Loader --------------------------------------------------------------------
function Q.load(path, propOverrides)
  Controls, Properties = nil, nil
  local env = setmetatable({}, { __index = _G })
  local chunk = assert(loadfile(path, "t", _G))
  chunk() -- defines GetProperties etc. with Controls == nil
  Properties = {}
  for _, p in ipairs(GetProperties()) do Properties[p.Name] = { Value = p.Value } end
  for k, v in pairs(propOverrides or {}) do assert(Properties[k], "no property " .. k); Properties[k].Value = v end
  local layout, graphics = GetControlLayout(Properties)
  Q.layout, Q.graphics = layout, graphics
  Controls = {}
  for _, d in ipairs(GetControls(Properties)) do
    assert(not Controls[d.Name], "duplicate control " .. d.Name)
    Controls[d.Name] = newControl(d)
  end
  for name in pairs(layout) do assert(Controls[name], "layout references unknown control " .. name) end
  for name in pairs(Controls) do assert(layout[name], "control missing from layout " .. name) end
  return Q
end

function Q.run(path)
  chunkRun = assert(loadfile(path, "t", _G))
  chunkRun()
end

Q.json = cjson
return Q
