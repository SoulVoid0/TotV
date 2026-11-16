-- The Home game mode (TotV OS).
--
-- A Home save is a world of the base mode (home.base_mode, Infinite by default) with
-- three rules on top, kept while a Home save runs:
--   * the clock is the real-life clock: the day/night cycle (daynightCycle_C.day, one
--     day = MaxTime units) is set to the local time every second, and its TimeScale is
--     trimmed so the game's own tick keeps pace in between;
--   * the player never gets hungry or tired: saveSlot_C.food and .sleep (on
--     mainGameInstance_C.save_gameInst) stay full and the pawn's drains stay at zero;
--   * the power never goes out: a blackout (powerControl_C.solar), the virus lockout
--     (powerControl_C.virus_pb) or a broken generator (generator_C.isBroken) is undone at
--     once, through post-hooks on those functions and a 200 ms watch, and the breakers go
--     back to where the player had them.
-- (Class and property names from the Multivoid project's reverse-engineering of 0.9.0n.)
local U = require('util')
local C = require('config')
local I = require('ipc')

local H = { active = false, offset_min = nil, last_day = nil, last_at = nil, breakers = nil,
            hooked = {}, restores = 0 }

local FULL = 100.0
local BREAKERS = { 'press_coord', 'press_downl', 'press_play', 'press_calc', 'press_light' }

-- Clock --------------------------------------------------------------------------------
local function real_minutes()
    local t = os.date('*t')
    return t.hour * 60 + t.min + t.sec / 60
end
H.real_minutes = real_minutes   -- tests replace it

local function cycle() return U.find_first('daynightCycle_C') end

local function sync_clock()
    local cyc = cycle()
    if not cyc then return end
    local max = tonumber(U.try(function() return cyc.MaxTime end))
    local day = tonumber(U.try(function() return cyc.day end) or U.try(function() return cyc.Day end))
    if not max or max <= 0 or not day then return end
    if H.offset_min == nil then
        -- Where 00:00 is on the cycle: the game's own hour and minute against `day`.
        local tz = U.try(function() return cyc.timeZ end)
        local h = tz and tonumber(U.try(function() return tz.X end))
        local m = tz and tonumber(U.try(function() return tz.Y end))
        if h == nil or m == nil then return end
        H.offset_min = ((day / max) * 1440 - (h * 60 + m)) % 1440
        U.log(string.format('home: clock calibrated (00:00 at %.1f game minutes)', H.offset_min))
    end
    U.try(function() cyc.realtime = true end)
    local want = ((H.real_minutes() + H.offset_min) % 1440) / 1440 * max
    local diff = math.abs(want - day)
    diff = math.min(diff, max - diff)
    if diff > max / 1440 * 0.5 then   -- more than half a minute off
        U.try(function() cyc.day = want end)
        U.try(function() cyc.Day = want end)
        H.last_day, H.last_at = want, U.ticks()   -- measure the pace from the new value
        return
    end
    -- Keep the game's own tick at real-time pace between the writes.
    local now = U.ticks()
    if H.last_day and H.last_at and now > H.last_at then
        local moved = (day - H.last_day) % max
        local per_s = moved / ((now - H.last_at) / 1000)
        local real_per_s = max / 86400
        local scale = tonumber(U.try(function() return cyc.TimeScale end))
        if scale and per_s > 0 and moved < max / 4 then
            local ns = math.max(0.01, math.min(100, scale * real_per_s / per_s))
            if math.abs(ns - scale) / scale > 0.05 then U.try(function() cyc.TimeScale = ns end) end
        end
    end
    H.last_day, H.last_at = U.try(function() return cyc.day end) or want, now
end

-- Needs ----------------------------------------------------------------------------------
local function keep_needs()
    local gi = U.game_instance()
    local slot = gi and U.try(function() return gi.save_gameInst end)
    if slot then
        for _, f in ipairs({ 'food', 'sleep' }) do
            local v = tonumber(U.try(function() return slot[f] end))
            if v and v < FULL then U.try(function() slot[f] = FULL end) end
        end
    end
    local p = U.main_player()
    if p then
        for _, f in ipairs({ 'foodDraining', 'sleepDraining' }) do
            local v = tonumber(U.try(function() return p[f] end))
            if v and v ~= 0 then U.try(function() p[f] = 0.0 end) end
        end
    end
end

-- Power ----------------------------------------------------------------------------------
local function panel()
    local gm = U.gamemode()
    local p = gm and U.try(function() return gm.powerControl end)
    if U.valid(p) then return p end
    return U.find_first('powerControl_C')
end

function H.restore_power()
    if not (H.active and C.values.home.power_always_on) then return end
    local p = panel()
    local fixed = false
    if p then
        if U.try(function() return p.disabled end) == true then
            U.try(function() p.disabled = false end)
            fixed = true
        end
        if fixed and H.breakers then
            for k, v in pairs(H.breakers) do U.try(function() p[k] = v end) end
        elseif not fixed then
            local b = {}
            for _, k in ipairs(BREAKERS) do b[k] = U.try(function() return p[k] end) end
            H.breakers = b
        end
        if fixed then
            U.try(function() p:buttonsVisibility() end)
            local servers = U.try(function() return p.servers end)
            if servers then
                U.try(function()
                    servers:ForEach(function(_, sv)
                        local s = sv:get()
                        U.try(function() s:setActive(true, false) end)
                    end)
                end)
            end
            U.try(function() p:playSND(true) end)
        end
    end
    for _, g in ipairs(U.find_all('generator_C')) do
        if U.try(function() return g.isBroken end) == true then
            U.try(function() g:fullFix() end)
            if U.try(function() return g.isBroken end) == true then U.try(function() g.isBroken = false end) end
            fixed = true
        end
    end
    if fixed then
        H.restores = H.restores + 1
        U.log('home: power restored (#' .. H.restores .. ')')
        I.emit('home_power_restored', { n = H.restores })
    end
end

-- Post-hooks on the functions that cut the power, so it comes back in the same frame.
local function hook_power()
    local p = panel()
    if not p then return end
    local cls = U.try(function() return p:GetClass() end)
    for _, name in ipairs({ 'solar', 'virus_pb' }) do
        if not H.hooked[name] and cls then
            local full = nil
            U.try(function()
                cls:ForEachFunction(function(fn)
                    if fn:GetFName():ToString() == name then full = fn:GetFullName(); return true end
                end)
            end)
            if full then
                full = full:gsub('^Function ', '')
                local ok = pcall(RegisterHook, full, function() end, function() H.restore_power() end)
                H.hooked[name] = ok and full or false
                U.log('home: hook', full, ok and 'registered' or 'failed')
            else
                H.hooked[name] = false
            end
        end
    end
end

-- Driven by main.lua -----------------------------------------------------------------------
function H.set_active(on)
    if on == H.active then return end
    H.active = on
    H.offset_min, H.last_day, H.last_at, H.breakers = nil, nil, nil, nil
    U.log('home: rules', on and 'on' or 'off')
    I.emit('home', { active = on })
end

function H.fast_tick()      -- every 200 ms
    if H.active and C.values.home.power_always_on then H.restore_power() end
end

function H.tick()           -- every second
    if not H.active then return end
    if C.values.home.realtime then pcall(sync_clock) end
    if C.values.home.no_needs then pcall(keep_needs) end
    if C.values.home.power_always_on then pcall(hook_power) end
end

return H
