-- File IPC with the host bridge (votv-os-bridge). Wine maps C:\ to / (LSIW),
-- so these are plain files in $XDG_RUNTIME_DIR/votv-os on the Linux side.
--   game-events.jsonl   mod -> host, one JSON object per line (append only)
--   host-commands.jsonl host -> mod, one JSON object per line (append only)
--   *.json              snapshots, replaced whole
local U = require('util')
local json = require('json')
local C = require('config')

local I = {}

local function path(name)
    return C.runtime_dir .. C.sep .. name:gsub('[/\\]', C.sep)
end
I.path = path

local cmd_offset = 0
local handlers = {}

function I.on(kind, fn) handlers[kind] = fn end

function I.emit(kind, data)
    local msg = data or {}
    msg.type = kind
    msg.t = os.time()
    U.append_file(path('game-events.jsonl'), json.encode(msg) .. '\n')
end

function I.snapshot(name, data)
    return U.write_file_atomic(path(name), json.encode(data))
end

-- True when the TotV OS bridge runs (it publishes the screens). Without it (plain
-- Windows, or the mod installed alone) the mod leaves the game exactly as it was.
function I.host_present()
    return U.file_size(path('screens.json')) ~= nil
end

function I.read_json(name)
    local raw = U.read_file(path(name))
    if not raw or raw == '' then return nil end
    return json.decode(raw)
end

-- Start reading commands from the current end, so a restarted game does not
-- replay the previous session's commands.
function I.init()
    cmd_offset = U.file_size(path('host-commands.jsonl')) or 0
    I.emit('hello', { mod = 'TotVOS', version = '1.0.0', game = '0.9.0n' })
end

-- Returns the decoded commands appended since the last poll.
function I.poll()
    local f = io.open(path('host-commands.jsonl'), 'rb')
    if not f then return {} end
    local size = f:seek('end')
    if size < cmd_offset then cmd_offset = 0 end   -- host truncated the file
    if size == cmd_offset then f:close(); return {} end
    f:seek('set', cmd_offset)
    local chunk = f:read(size - cmd_offset)
    f:close()
    local out = {}
    local consumed = 0
    for line, nl in chunk:gmatch('([^\n]*)(\n)') do
        consumed = consumed + #line + #nl
        if line ~= '' then
            local msg = json.decode(line)
            if type(msg) == 'table' then out[#out + 1] = msg end
        end
    end
    cmd_offset = cmd_offset + consumed   -- a partial last line waits for the next poll
    return out
end

function I.dispatch(cmds)
    for _, msg in ipairs(cmds) do
        local h = handlers[msg.type]
        if h then
            local ok, err = pcall(h, msg)
            if not ok then U.log('command', msg.type, 'failed:', err) end
        end
    end
end

return I
