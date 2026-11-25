-- Pure-Lua JSON with the parts of the lua-cjson interface the tests use (encode, decode, null).
-- qsys_mock.lua uses lua-cjson when it is installed and falls back to this file otherwise,
-- so the tests run on machines (e.g. Windows) where cjson can't easily be built.

local M = {}
M.null = setmetatable({}, { __tostring = function() return "null" end })

local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function isArray(t)
  local n = 0
  for k in pairs(t) do
    if math.type(k) ~= "integer" or k < 1 then return false end
    if k > n then n = k end
  end
  if n == 0 then return false end -- empty table encodes as {} like cjson
  for i = 1, n do if t[i] == nil then return false end end
  return true, n
end

local function enc(v, out)
  local tv = type(v)
  if v == nil or v == M.null then out[#out + 1] = "null"
  elseif tv == "boolean" then out[#out + 1] = tostring(v)
  elseif tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then error("cannot encode " .. tostring(v)) end
    if math.type(v) == "integer" then out[#out + 1] = tostring(v)
    elseif v == math.floor(v) and math.abs(v) < 1e15 then out[#out + 1] = string.format("%d", v)
    else out[#out + 1] = string.format("%.14g", v) end
  elseif tv == "string" then
    out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c)
      return escapes[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
  elseif tv == "table" then
    local arr, n = isArray(v)
    if arr then
      out[#out + 1] = "["
      for i = 1, n do if i > 1 then out[#out + 1] = "," end enc(v[i], out) end
      out[#out + 1] = "]"
    else
      out[#out + 1] = "{"
      local first = true
      for k, x in pairs(v) do
        if not first then out[#out + 1] = "," end
        first = false
        enc(tostring(k), out); out[#out + 1] = ":"; enc(x, out)
      end
      out[#out + 1] = "}"
    end
  else
    error("cannot encode a " .. tv)
  end
end

function M.encode(v)
  local out = {}
  enc(v, out)
  return table.concat(out)
end

function M.decode(s)
  local pos = 1
  local function ws() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
  local function err(msg) error(("json: %s at position %d"):format(msg, pos), 0) end
  local value

  local function str()
    pos = pos + 1
    local parts = {}
    while true do
      local c = s:sub(pos, pos)
      if c == "" then err("unterminated string") end
      if c == '"' then pos = pos + 1; return table.concat(parts) end
      if c == "\\" then
        local e = s:sub(pos + 1, pos + 1)
        local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
        if map[e] then parts[#parts + 1] = map[e]; pos = pos + 2
        elseif e == "u" then
          local cp = tonumber(s:sub(pos + 2, pos + 5), 16) or err("bad \\u escape")
          pos = pos + 6
          if cp >= 0xD800 and cp <= 0xDBFF and s:sub(pos, pos + 1) == "\\u" then
            local lo = tonumber(s:sub(pos + 2, pos + 5), 16)
            if lo and lo >= 0xDC00 and lo <= 0xDFFF then
              cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00); pos = pos + 6
            end
          end
          parts[#parts + 1] = utf8.char(cp)
        else err("bad escape") end
      else
        local j = s:find('["\\]', pos) or #s + 1
        parts[#parts + 1] = s:sub(pos, j - 1); pos = j
      end
    end
  end

  function value()
    ws()
    local c = s:sub(pos, pos)
    if c == "{" then
      pos = pos + 1; local t = {}; ws()
      if s:sub(pos, pos) == "}" then pos = pos + 1; return t end
      while true do
        ws(); if s:sub(pos, pos) ~= '"' then err("expected key") end
        local k = str(); ws()
        if s:sub(pos, pos) ~= ":" then err("expected ':'") end
        pos = pos + 1
        t[k] = value(); ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "}" then return t elseif d ~= "," then err("expected ',' or '}'") end
      end
    elseif c == "[" then
      pos = pos + 1; local t = {}; ws()
      if s:sub(pos, pos) == "]" then pos = pos + 1; return t end
      while true do
        t[#t + 1] = value(); ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "]" then return t elseif d ~= "," then err("expected ',' or ']'") end
      end
    elseif c == '"' then return str()
    elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4; return M.null
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      if not num or num == "" then err("unexpected character '" .. c .. "'") end
      pos = pos + #num
      return math.tointeger(tonumber(num)) or tonumber(num)
    end
  end

  local v = value(); ws()
  if pos <= #s then err("trailing data") end
  return v
end

return M
