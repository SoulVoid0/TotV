-- TotV OS integration for Voices of the Void 0.9.0n (UE4SS Lua; loaded by shimloader).
--
-- Talks to the TotV OS host bridge through files in the runtime dir (see ipc.lua):
--   saves.lua         no main menu: the save the host chooses runs (target.json) --
--                     "default" at boot, the user's own at login, any from VotV Saves
--   home.lua          the Home game mode: real-life clock, no hunger or tiredness,
--                     power that never goes out
--   pcscreen.lua      the in-game PC shows / becomes the KDE Plasma desktop
--   relay.lua         the KDE "VotV PC" app drives the game's own PC UI;
--                     the inventory moves to a second monitor when there is one
--   perf.lua          invisible performance settings
local U = require('util')
local C = require('config')
local I = require('ipc')
local S = require('saves')
local H = require('home')
local P = require('pcscreen')
local R = require('relay')
local F = require('perf')

C.reload()
I.init()
U.log('loaded; runtime dir', C.runtime_dir, '| OS user', tostring(C.session_user()))

I.on('ping', function(msg) I.emit('pong', { req = msg.req }) end)
I.on('leave_pc', function() P.leave_from_host() end)
I.on('overlay_shown', function(msg) F.set_hidden(msg.shown == true) end)
I.on('config_reload', function()
    if C.reload() then P.reapply_camera() end
end)
I.on('save_now', function(msg) I.emit('ack', { of = 'save_now', req = msg.req, ok = S.save_running_world() }) end)
I.on('status', function(msg)
    I.emit('status', { req = msg.req, save = S.state, slot = S.slot, name = S.name, mode = S.mode,
                       home = H.active, pc_using = P.using, inventory_mirrored = R.inv_open, screens = R.screens })
end)

local STEP = 50
local busy = false
local since_slow = 0
local since_pc = 0
local since_home = 0

local function tick()
    I.dispatch(I.poll())
    since_pc = since_pc + STEP
    if since_pc >= 100 then
        since_pc = 0
        local ok, err = pcall(P.tick)
        if not ok then U.warn_once('pctick' .. tostring(err), 'pc tick:', err) end
    end
    local ok, err = pcall(R.tick)
    if not ok then U.warn_once('rtick' .. tostring(err), 'relay tick:', err) end

    since_home = since_home + STEP
    if since_home >= 200 then
        since_home = 0
        ok, err = pcall(H.fast_tick)
        if not ok then U.warn_once('hfast' .. tostring(err), 'home:', err) end
    end

    since_slow = since_slow + STEP
    if since_slow >= 1000 then
        since_slow = 0
        if C.reload() then P.reapply_camera() end
        R.read_screens()
        ok, err = pcall(S.step)
        if not ok then U.warn_once('saves' .. tostring(err), 'saves:', err) end
        H.set_active(S.is_home())
        ok, err = pcall(H.tick)
        if not ok then U.warn_once('home' .. tostring(err), 'home:', err) end
        F.tick(S.state == 'in-game' and I.host_present())
    end
end

LoopAsync(STEP, function()
    U.advance(STEP)
    if busy then return false end   -- the game thread is busy (level load); skip
    busy = true
    ExecuteInGameThread(function()
        local ok, err = pcall(tick)
        if not ok then U.warn_once('tick' .. tostring(err), 'tick:', err) end
        busy = false
    end)
    return false
end)
