-- Boot straight into the save named after the OS user.
--
-- VotV 0.9.0n has one travel path into a world: the menu loads a slot with
-- GameplayStatics.LoadGameFromSlot, registers it on the GameInstance with
-- mainGameInstance_C.setSaveSlotObject(save, SlotName), sets loadObjects, copies the
-- save's world rules (saveSlot_C.localGameRules -> mainGameInstance_C.gameRules) and its
-- day (savedtime.Z -> startDay), then opens the gameplay map `untitled_1`. A slot's
-- game mode is its name prefix: ui_saveSlots_C.getSavePrefix(mode). This module does
-- the same from the menu, without the player touching it. (Names verified against
-- the game by the Multivoid project's reverse-engineering of 0.9.0n.)
local U = require('util')
local C = require('config')
local I = require('ipc')

local A = { done = false, state = 'waiting', slot = nil }

local GAMEPLAY_MAP = 'untitled_1'
local tries = 0
local opened_at = nil

local function sanitize(name)
    name = (name or ''):gsub('[^%w%-_ ]', ''):gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' then name = 'TotV' end
    return name:sub(1, 32)
end

local function in_gameplay()
    local p = U.find_first('mainPlayer_C')
    if not p then return false end
    local loc = U.try(function() return p:K2_GetActorLocation() end)
    if not loc then return false end
    return math.abs(loc.X) + math.abs(loc.Y) + math.abs(loc.Z) > 100
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

-- Copy every field of struct property `name` from `src` to `dst` (both UObjects).
-- gameRules members are bools, bytes and one float, so field-by-field is a full copy.
local function copy_struct(dst, dst_prop, src, src_prop)
    local s = U.try(function() return src[src_prop] end)
    local d = U.try(function() return dst[dst_prop] end)
    if s == nil or d == nil then return 0 end
    local n = 0
    U.try(function()
        s:ForEachProperty(function(prop)
            local f = prop:GetFName():ToString()
            local ok = pcall(function() d[f] = s[f] end)
            if ok then n = n + 1 end
        end)
    end)
    -- Write back in case the struct accessor returned a copy.
    pcall(function() dst[dst_prop] = d end)
    return n
end

local function slot_prefix(mode)
    local ui = U.find_first('ui_saveSlots_C')
    if not ui then return nil end
    local r = U.try(function() return ui:getSavePrefix(mode) end)
    if r == nil then return nil end
    return U.to_str(r)
end

function A.step()
    if A.done then return end
    if not C.values.autoload.enabled then A.done = true; return end
    -- Only on TotV OS (a user name from the installer); a plain install keeps its menu.
    if not C.save_name() then A.done = true; A.state = 'off'; return end

    if in_gameplay() then
        A.done = true
        A.state = 'in-game'
        U.log('autoload: in gameplay on slot', A.slot or '?')
        I.emit('in_game', { slot = A.slot })
        return
    end
    if opened_at and (U.ticks() - opened_at) < 15000 then return end  -- the map is loading

    local gi = U.game_instance()
    local gs = U.statics()
    if not (gi and gs) then return end
    local mode = tonumber(C.values.autoload.mode) or 0
    local prefix = slot_prefix(mode)
    if prefix == nil then return end   -- menu not up yet (warning screen / preLoad)

    local name = sanitize(C.save_name())
    local slot = prefix .. name
    A.slot = slot

    local exists = U.try(function() return gs:DoesSaveGameExist(slot, 0) end)
    local save
    if exists then
        save = U.try(function() return gs:LoadGameFromSlot(slot, 0) end)
    else
        local cls = find_class('saveSlot_C')
        if not cls then U.warn_once('nosaveclass', 'autoload: saveSlot_C class not found yet'); return end
        save = U.try(function() return gs:CreateSaveGameObject(cls) end)
        if U.valid(save) then
            -- A new world starts with the menu's current rules, as the game's New Game does.
            copy_struct(save, 'localGameRules', gi, 'gameRules')
        end
    end
    if not U.valid(save) then
        U.warn_once('nosave', 'autoload: could not ' .. (exists and 'load' or 'create') .. ' slot', slot)
        return
    end

    U.try(function() gi:setSaveSlotObject(save, slot) end)
    U.try(function() gi.loadObjects = true end)
    U.try(function() gi.GameMode = mode end)
    copy_struct(gi, 'gameRules', save, 'localGameRules')
    local t = U.try(function() return save.savedtime end)
    if t then U.try(function() gi.startDay = t.Z end) end
    if not exists then
        -- Write it now so the slot is listed in the game's own menu from the start.
        U.try(function() gs:SaveGameToSlot(save, slot, 0) end)
    end

    tries = tries + 1
    U.log(string.format('autoload: %s slot "%s" (mode %d), opening %s (try %d)',
        exists and 'loading' or 'creating', slot, mode, GAMEPLAY_MAP, tries))
    I.emit('autoload', { slot = slot, created = not exists, try = tries })
    U.console('open ' .. GAMEPLAY_MAP)
    opened_at = U.ticks()
end

return A
