-- Settings: built-in defaults, overlaid by the system file the OS installs
-- (C:\etc\totv\votv.json) and the user's file the calibration app writes
-- (VOTV_OS_USERCFG, normally C:\home\<user>\.config\totv\votv.json).
-- Re-read whenever either file changes, so calibration is live.
local U = require('util')
local json = require('json')

local C = {}

local DEFAULTS = {
    autoload = { enabled = true, mode = 0 },  -- mode: 0 Story, 1 Infinite, 3 Custom, 4 Sandbox
    pc = {
        replace_ingame_ui = true,   -- the in-game laptop shows the KDE desktop
        ingame_fps = 2,             -- texture refreshes per second while looking at it from afar
        align_camera = true,        -- line the in-game screen up with the real screen while using it
        blend = 0.35,               -- seconds of camera blend in/out
        overlay_delay = 0.4,        -- seconds before the real KDE window covers the screen
        camera = {
            distance_scale = 1.0, offset_right = 0.0, offset_up = 0.0, offset_forward = 0.0,
            pitch = 0.0, yaw = 0.0, roll = 0.0, fov = 0.0, preview = false,
        },
    },
    inventory = { second_screen = 'auto' },  -- auto: on when 2+ screens; on; off
    relay = { snapshot_hz = 4 },
    perf = { enabled = true },
}

local function deep_merge(dst, src)
    for k, v in pairs(src) do
        if type(v) == 'table' and type(dst[k]) == 'table' and not v[1] then
            deep_merge(dst[k], v)
        else
            dst[k] = v
        end
    end
    return dst
end

local function deep_copy(t)
    if type(t) ~= 'table' then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = deep_copy(v) end
    return r
end

C.values = deep_copy(DEFAULTS)

local function env(name, fallback)
    local v = os.getenv(name)
    if v and v ~= '' then return v end
    return fallback
end

-- '\\' in the game (UE4SS is a Windows build); '/' when the tests run on Linux.
C.sep = package.config:sub(1, 1)
C.runtime_dir = env('VOTV_OS_RUNTIME', 'C:\\run\\votv-os')
C.system_file = env('VOTV_OS_SYSCFG', 'C:\\etc\\totv\\votv.json')
C.user_file = env('VOTV_OS_USERCFG', nil)
C.user_conf = env('VOTV_OS_USERCONF', 'C:\\etc\\totv\\user.conf')

local last_raw = {}

function C.reload()
    local changed = false
    for _, path in ipairs({ C.system_file, C.user_file }) do
        if path then
            local raw = U.read_file(path) or ''
            if raw ~= last_raw[path] then
                last_raw[path] = raw
                changed = true
            end
        end
    end
    if not changed then return false end
    local v = deep_copy(DEFAULTS)
    for _, path in ipairs({ C.system_file, C.user_file }) do
        local raw = path and last_raw[path]
        if raw and raw ~= '' then
            local t, err = json.decode(raw)
            if type(t) == 'table' then deep_merge(v, t)
            else U.log('config: ignoring', path, err) end
        end
    end
    C.values = v
    return true
end

-- /etc/totv/user.conf is shell syntax (USERNAME=..., SAVE_NAME=...).
function C.user_conf_values()
    local raw = U.read_file(C.user_conf)
    local out = {}
    if not raw then return out end
    for line in raw:gmatch('[^\r\n]+') do
        local k, v = line:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
        if k then
            v = v:gsub('^"(.*)"$', '%1'):gsub("^'(.*)'$", '%1')
            out[k] = v
        end
    end
    return out
end

function C.save_name()
    local env_name = os.getenv('VOTV_OS_SAVE_NAME')
    if env_name and env_name ~= '' then return env_name end
    local u = C.user_conf_values()
    return u.SAVE_NAME or u.USERNAME
end

return C
