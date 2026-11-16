-- Minimal JSON encode/decode for the TotV OS bridge (pure Lua 5.4, no deps).
local json = {}

local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
                  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function encode_string(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return escapes[c] or string.format('\\u%04x', c:byte())
    end) .. '"'
end

local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= 'number' or k <= 0 or math.floor(k) ~= k then return false end
        n = math.max(n, k)
    end
    return n == #t
end

local encode
encode = function(v, out)
    local t = type(v)
    if v == nil or v == json.null then out[#out + 1] = 'null'
    elseif t == 'boolean' then out[#out + 1] = v and 'true' or 'false'
    elseif t == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = '0'
        elseif math.type(v) == 'integer' then out[#out + 1] = tostring(v)
        else out[#out + 1] = string.format('%.6g', v) end
    elseif t == 'string' then out[#out + 1] = encode_string(v)
    elseif t == 'table' then
        if next(v) == nil then out[#out + 1] = (getmetatable(v) == json.object_mt) and '{}' or '[]'
        elseif is_array(v) then
            out[#out + 1] = '['
            for i = 1, #v do
                if i > 1 then out[#out + 1] = ',' end
                encode(v[i], out)
            end
            out[#out + 1] = ']'
        else
            out[#out + 1] = '{'
            local first = true
            for k, val in pairs(v) do
                if not first then out[#out + 1] = ',' end
                first = false
                out[#out + 1] = encode_string(tostring(k))
                out[#out + 1] = ':'
                encode(val, out)
            end
            out[#out + 1] = '}'
        end
    else
        out[#out + 1] = 'null'
    end
end

json.null = setmetatable({}, { __tostring = function() return 'null' end })
json.object_mt = {}
function json.object(t) return setmetatable(t or {}, json.object_mt) end

function json.encode(v)
    local out = {}
    encode(v, out)
    return table.concat(out)
end

-- Decoder ------------------------------------------------------------------
local function skip_ws(s, i)
    local _, e = s:find('^[ \n\r\t]*', i)
    return e + 1
end

local decode_value

local function decode_string(s, i)
    local buf, j = {}, i + 1
    while true do
        local c = s:sub(j, j)
        if c == '' then error('unterminated string') end
        if c == '"' then return table.concat(buf), j + 1 end
        if c == '\\' then
            local n = s:sub(j + 1, j + 1)
            local map = { b = '\b', f = '\f', n = '\n', r = '\r', t = '\t', ['"'] = '"', ['\\'] = '\\', ['/'] = '/' }
            if map[n] then buf[#buf + 1] = map[n]; j = j + 2
            elseif n == 'u' then
                local cp = tonumber(s:sub(j + 2, j + 5), 16)
                if not cp then error('bad \\u escape') end
                j = j + 6
                if cp >= 0xD800 and cp <= 0xDBFF and s:sub(j, j + 1) == '\\u' then
                    local lo = tonumber(s:sub(j + 2, j + 5), 16)
                    if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                        j = j + 6
                    end
                end
                buf[#buf + 1] = utf8.char(cp)
            else error('bad escape') end
        else
            buf[#buf + 1] = c
            j = j + 1
        end
    end
end

decode_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == '{' then
        local obj = json.object()
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == '}' then return obj, i + 1 end
        while true do
            i = skip_ws(s, i)
            if s:sub(i, i) ~= '"' then error('expected key at ' .. i) end
            local k; k, i = decode_string(s, i)
            i = skip_ws(s, i)
            if s:sub(i, i) ~= ':' then error('expected : at ' .. i) end
            local v; v, i = decode_value(s, i + 1)
            obj[k] = v
            i = skip_ws(s, i)
            local d = s:sub(i, i)
            if d == '}' then return obj, i + 1 end
            if d ~= ',' then error('expected , or } at ' .. i) end
            i = i + 1
        end
    elseif c == '[' then
        local arr = {}
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == ']' then return arr, i + 1 end
        while true do
            local v; v, i = decode_value(s, i)
            arr[#arr + 1] = v
            i = skip_ws(s, i)
            local d = s:sub(i, i)
            if d == ']' then return arr, i + 1 end
            if d ~= ',' then error('expected , or ] at ' .. i) end
            i = i + 1
        end
    elseif c == '"' then return decode_string(s, i)
    elseif s:sub(i, i + 3) == 'true' then return true, i + 4
    elseif s:sub(i, i + 4) == 'false' then return false, i + 5
    elseif s:sub(i, i + 3) == 'null' then return nil, i + 4
    else
        local num = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', i)
        if not num or num == '' then error('unexpected character at ' .. i) end
        return tonumber(num), i + #num
    end
end

function json.decode(s)
    local ok, v = pcall(function()
        local val, i = decode_value(s, 1)
        i = skip_ws(s, i)
        if i <= #s then error('trailing data at ' .. i) end
        return val
    end)
    if ok then return v end
    return nil, v
end

return json
