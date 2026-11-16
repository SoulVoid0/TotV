-- Settings: built-in defaults, overlaid by the system file the OS installs
-- (Z:\etc\totv\votv.json) and the logged-in user's file the calibration app
-- writes (Z:\.VotV\config\<user>.json; the user comes from session.json in the
-- runtime dir, which the bridge writes at login and removes at logout).
-- Re-read whenever a file changes, so calibration is live.
local U = require('util')
local json = require('json')

local C = {}

local DEFAULTS = {
    -- Which save runs is the host's choice (target.json); these say how to get there.
    saves = { enabled = true, save_before_switch = true, hide_menu = true },
    -- The Home game mode (TotV OS): a world on top of base_mode (0 Story, 1 Infinite,
    -- 3 Custom, 4 Sandbox) with the real-life clock, no hunger or tiredness, and power
    -- that never goes out.
    home = { base_mode = 1, realtime = true, no_needs = true, power_always_on = true },
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
C.runtime_dir = env('VOTV_OS_RUNTIME', 'Z:\\run\\totv\\votv-os')
C.system_file = env('VOTV_OS_SYSCFG', 'Z:\\etc\\totv\\votv.json')
C.user_cfg_dir = env('VOTV_OS_USERCFG_DIR', 'Z:\\.VotV\\config')
C.saves_dir = env('VOTV_OS_SAVES', 'Z:\\.VotV\\saves')
C.fixed_user_file = env('VOTV_OS_USERCFG', nil)
C.user_file = C.fixed_user_file

-- The user logged in to the OS right now (nil: nobody, the shared Home save runs).
function C.session_user()
    local raw = U.read_file(C.runtime_dir .. C.sep .. 'session.json')
    if not raw or raw == '' then return nil end
    local t = json.decode(raw)
    if type(t) == 'table' and type(t.user) == 'string' and t.user:match('^[%w_%-]+$') then return t.user end
    return nil
end

local last_raw = {}

function C.reload()
    if not C.fixed_user_file then
        local u = C.session_user()
        C.user_file = u and (C.user_cfg_dir .. C.sep .. u .. '.json') or nil
    end
    local changed = false
    if C.user_file ~= last_raw.__user_file then
        last_raw.__user_file = C.user_file
        changed = true
    end
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

return C
