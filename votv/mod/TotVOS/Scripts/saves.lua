-- Which save runs, and the end of the main menu.
--
-- On TotV OS the game never shows its main menu. The host decides which save runs and
-- writes it to target.json in the runtime dir:
--   { "seq": 7, "name": "alice", "title": "alice", "mode": "home", "create": true,
--     "rules": { ... optional gameRules overrides for a new save ... } }
-- at boot (the shared "default" Home save), at login (the user's own save, named after
-- the user), at logout (back to "default") and whenever the VotV Saves app loads a save.
-- This module converges on it: whenever the target changes, or the game falls back to
-- its menu (quit, death, a crash of the world), it saves the running world and loads
-- the target the way the game's own menu does.
--
-- VotV 0.9.0n has one travel path into a world: LoadGameFromSlot (or CreateSaveGameObject
-- for a new world), mainGameInstance_C.setSaveSlotObject(save, SlotName), loadObjects,
-- the save's rules (saveSlot_C.localGameRules -> mainGameInstance_C.gameRules) and its day
-- (savedtime.Z -> startDay), GameMode, then `open untitled_1`. A slot's game mode is its
-- name prefix, ui_saveSlots_C.getSavePrefix(mode); the prefixes are learned from the menu
-- at the first boot and kept in Z:\.VotV\saves\prefixes.json so a save can be switched from
-- inside a world. (Names from the Multivoid project's reverse-engineering of 0.9.0n.)
local U = require('util')
local C = require('config')
local I = require('ipc')
local json = require('json')

local S = { state = 'waiting', slot = nil, name = nil, mode = nil, target = nil, applied_seq = nil,
            loaded_seq = nil, prefixes = {}, opened_at = nil, phase_at = nil, tries = 0 }

local GAMEPLAY_MAP = 'untitled_1'
local MENU_MAP = 'menu'
local MODES = { story = 0, infinite = 1, custom = 3, sandbox = 4 }
local MENU_WIDGETS = { 'ui_mainMenu_C', 'ui_menu_C', 'ui_saveSlots_C', 'ui_newGame_C', 'ui_menuSettings_C',
                       'ui_mainmenu_C', 'ui_startMenu_C' }

function S.sanitize(name)
    name = tostring(name or ''):gsub('[^%w%-_ ]', ''):gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' then name = 'default' end
    return name:sub(1, 48)
end

-- The game mode a target runs in: Home runs on its base mode with TotV's rules on top.
function S.game_mode(mode, base)
    if mode == 'home' or mode == nil then return tonumber(base) or tonumber(C.values.home.base_mode) or 1 end
    if type(mode) == 'number' then return mode end
    return MODES[tostring(mode)] or 1
end

function S.is_home() return S.state == 'in-game' and S.mode == 'home' end

-- Prefixes ---------------------------------------------------------------------------
local function prefix_file() return C.saves_dir .. C.sep .. 'prefixes.json' end

local function load_prefixes()
    local raw = U.read_file(prefix_file())
    local t = raw and json.decode(raw)
    if type(t) == 'table' then
        for k, v in pairs(t) do S.prefixes[tonumber(k) or k] = v end
    end
end

local function learn_prefixes()
    local ui = U.find_first('ui_saveSlots_C')
    if not ui then return false end
    local changed = false
    for m = 0, 7 do
        local r = U.try(function() return ui:getSavePrefix(m) end)
        if r ~= nil then
            local p = U.to_str(r)
            if S.prefixes[m] ~= p then S.prefixes[m] = p; changed = true end
        end
    end
    if changed then
        local out = {}
        for k, v in pairs(S.prefixes) do out[tostring(k)] = v end
        U.write_file_atomic(prefix_file(), json.encode(out))
        I.snapshot('prefixes.json', out)
    end
    return S.prefixes[0] ~= nil
end

-- World state -------------------------------------------------------------------------
local function in_gameplay()
    local p = U.find_first('mainPlayer_C')
    if not p then return false end
    local loc = U.try(function() return p:K2_GetActorLocation() end)
    if not loc then return false end
    return math.abs(loc.X) + math.abs(loc.Y) + math.abs(loc.Z) > 100
end
S.in_gameplay = in_gameplay

local function in_menu()
    local gm = U.gamemode()
    local flag = gm and U.try(function() return gm.isMainMenu end)
    if flag == true then return true end
    return U.find_first('ui_saveSlots_C') ~= nil and not in_gameplay()
end
S.in_menu = in_menu

-- No main menu: its widgets are hidden and the view is black while the save loads.
local function hide_menu()
    if not C.values.saves.hide_menu then return end
    for _, cls in ipairs(MENU_WIDGETS) do
        for _, w in ipairs(U.find_all(cls)) do
            if U.try(function() return w:IsVisible() end) ~= false then
                U.try(function() w:SetVisibility(1) end)   -- Collapsed
            end
        end
    end
    local pc = U.player_controller()
    local pcm = pc and U.try(function() return pc.PlayerCameraManager end)
    if pcm then U.try(function() pcm:SetManualCameraFade(1.0, { R = 0, G = 0, B = 0, A = 1 }, false) end) end
end

local function unfade()
    local pc = U.player_controller()
    local pcm = pc and U.try(function() return pc.PlayerCameraManager end)
    if pcm then U.try(function() pcm:StopCameraFade() end) end
end

local function find_class(short)
    local cls = U.try(FindObject, 'BlueprintGeneratedClass', nil, short, true)
    if U.valid(cls) then return cls end
    local hit = nil
    U.try(ForEachUObject, function(obj)
        if hit then return end
        if U.obj_name(obj) == short then
            local cn = U.class_name(obj)
            if cn == 'BlueprintGeneratedClass' or cn == 'Class' then hit = obj end
        end
    end)
    return hit
end

-- Copy every field of struct property src[src_prop] into dst[dst_prop].
-- gameRules members are bools, bytes and one float, so field-by-field is a full copy.
local function copy_struct(dst, dst_prop, src, src_prop)
    local s = U.try(function() return src[src_prop] end)
    local d = U.try(function() return dst[dst_prop] end)
    if s == nil or d == nil then return 0 end
    local n = 0
    U.try(function()
        s:ForEachProperty(function(prop)
            local f = prop:GetFName():ToString()
            if pcall(function() d[f] = s[f] end) then n = n + 1 end
        end)
    end)
    pcall(function() dst[dst_prop] = d end)
    return n
end

-- Rules overrides by short field name (Blueprint struct fields carry a GUID suffix).
local function apply_rules(save, rules)
    if type(rules) ~= 'table' then return end
    local r = U.try(function() return save.localGameRules end)
    if r == nil then return end
    for k, v in pairs(rules) do
        local done = pcall(function() r[k] = v end)
        if not done then
            U.try(function()
                r:ForEachProperty(function(prop)
                    local n = prop:GetFName():ToString()
                    if n:find('^' .. k .. '_%d+_') then r[n] = v; return true end
                end)
            end)
        end
    end
    pcall(function() save.localGameRules = r end)
end

-- The game's own save of the running world, before leaving it.
local SAVE_FUNCTIONS = { savegame = true, saveall = true, saveworld = true, save = true, savegameall = true }
function S.save_running_world()
    local gm = U.gamemode()
    if not gm then return false end
    local fn = U.find_function_name(gm, 'save', function(n) return SAVE_FUNCTIONS[n:lower()] == true end)
    if not fn then U.warn_once('nosavefn', 'saves: no save function on mainGamemode_C; the world is not saved before a switch'); return false end
    local ok = U.try(function() gm[fn](gm); return true end)
    if ok then U.log('saves: saved the running world through', fn) end
    return ok == true
end

-- Target ------------------------------------------------------------------------------
local function read_target()
    local t = I.read_json('target.json')
    if type(t) ~= 'table' or t.name == nil then return nil end
    t.name = S.sanitize(t.name)
    t.seq = tonumber(t.seq) or 0
    return t
end

local function open_target(t)
    local gi, gs = U.game_instance(), U.statics()
    if not (gi and gs) then return false end
    local mode = S.game_mode(t.mode, t.base_mode)
    local prefix = S.prefixes[mode]
    if prefix == nil then
        if not in_menu() then
            -- Prefixes are learned in the menu: go there once (hidden), then come back.
            U.log('saves: slot prefixes unknown, passing through the menu')
            U.console('open ' .. MENU_MAP)
            S.opened_at = U.ticks()
        end
        return false
    end
    local slot = prefix .. t.name
    local exists = U.try(function() return gs:DoesSaveGameExist(slot, 0) end)
    local save
    if exists then
        save = U.try(function() return gs:LoadGameFromSlot(slot, 0) end)
    elseif t.create ~= false then
        local cls = find_class('saveSlot_C')
        if not cls then U.warn_once('nosaveclass', 'saves: saveSlot_C class not found yet'); return false end
        save = U.try(function() return gs:CreateSaveGameObject(cls) end)
        if U.valid(save) then
            copy_struct(save, 'localGameRules', gi, 'gameRules')   -- as the game's New Game does
            apply_rules(save, t.rules)
        end
    else
        U.warn_once('missing' .. slot, 'saves: slot', slot, 'does not exist and the target says create=false')
        I.emit('save_missing', { name = t.name, slot = slot })
        S.applied_seq = t.seq
        return false
    end
    if not U.valid(save) then
        U.warn_once('nosave' .. slot, 'saves: could not ' .. (exists and 'load' or 'create') .. ' slot', slot)
        return false
    end

    U.try(function() gi:setSaveSlotObject(save, slot) end)
    U.try(function() gi.loadObjects = true end)
    U.try(function() gi.GameMode = mode end)
    copy_struct(gi, 'gameRules', save, 'localGameRules')
    local st = U.try(function() return save.savedtime end)
    if st then U.try(function() gi.startDay = st.Z end) end
    if not exists then U.try(function() gs:SaveGameToSlot(save, slot, 0) end) end

    S.tries = S.tries + 1
    S.slot, S.name, S.mode, S.target = slot, t.name, t.mode or 'home', t
    S.applied_seq, S.state, S.opened_at = t.seq, 'loading', U.ticks()
    S.created = not exists
    U.log(string.format('saves: %s slot "%s" (%s, game mode %d), opening %s',
        exists and 'loading' or 'creating', slot, tostring(S.mode), mode, GAMEPLAY_MAP))
    I.emit('save_loading', { name = t.name, slot = slot, mode = S.mode, created = not exists, seq = t.seq })
    U.console('open ' .. GAMEPLAY_MAP)
    return true
end

function S.step()
    if not C.values.saves.enabled then return end
    local menu = in_menu()
    if menu then learn_prefixes() end
    local t = read_target()
    if not t then return end   -- not on TotV OS (no host): the game is left as it is
    if menu then hide_menu() end

    -- A world is loading: wait for it, at most 60 s.
    if S.state == 'loading' then
        if in_gameplay() then
            S.state = 'in-game'
            S.loaded_seq = S.applied_seq
            unfade()
            U.log('saves: in the world of slot', S.slot)
            I.emit('save_loaded', { name = S.name, slot = S.slot, mode = S.mode, created = S.created, seq = S.loaded_seq })
            I.emit('in_game', { slot = S.slot })
        elseif U.ticks() - S.opened_at > 60000 then
            U.log('saves: slot', S.slot, 'did not load in 60 s; trying again')
            S.state = 'waiting'
        else
            return
        end
    end
    if S.state == 'saving' then
        if U.ticks() - S.phase_at < 1500 then return end
        S.state = 'switch'
    end
    if S.opened_at and S.state == 'waiting' and U.ticks() - S.opened_at < 3000 then return end

    if S.state == 'in-game' then
        if menu then
            -- The game went back to its menu (quit, death): there is no menu, so the
            -- target comes back.
            U.log('saves: the game returned to the menu; loading', t.name, 'again')
            S.state = 'waiting'
        elseif t.seq ~= S.loaded_seq then
            if C.values.saves.save_before_switch then S.save_running_world() end
            S.state, S.phase_at = 'saving', U.ticks()
            I.emit('save_switching', { from = S.name, to = t.name, seq = t.seq })
            return
        else
            return
        end
    end
    if S.state == 'switch' or S.state == 'waiting' then
        if not (menu or in_gameplay()) then return end   -- boot screens, a level in flight
        if open_target(t) then return end
        if S.state == 'switch' then S.state = 'waiting' end
    end
end

I.on('reload_save', function() S.loaded_seq = -1 end)

load_prefixes()
return S
