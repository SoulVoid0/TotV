-- TotV OS integration for Voices of the Void 0.9.0n (UE4SS Lua; loaded by shimloader).
--
-- Talks to the TotV OS host bridge through files in the runtime dir (see ipc.lua):
--   autoload.lua      boot straight into the save named after the OS user
--   pcscreen.lua      the in-game PC shows / becomes the KDE Plasma desktop
--   relay.lua         the KDE "VotV PC" app drives the game's own PC UI;
--                     the inventory moves to a second monitor when there is one
--   perf.lua          invisible performance settings
local U = require('util')
local C = require('config')
local I = require('ipc')
local A = require('autoload')
local P = require('pcscreen')
local R = require('relay')
local F = require('perf')

C.reload()
I.init()
U.log('loaded; runtime dir', C.runtime_dir, '| save name', tostring(C.save_name()))

I.on('ping', function(msg) I.emit('pong', { req = msg.req }) end)
I.on('leave_pc', function() P.leave_from_host() end)
I.on('overlay_shown', function(msg) F.set_hidden(msg.shown == true) end)
I.on('config_reload', function()
    if C.reload() then P.reapply_camera() end
end)
I.on('status', function(msg)
    I.emit('status', { req = msg.req, autoload = A.state, slot = A.slot, pc_using = P.using,
                       inventory_mirrored = R.inv_open, screens = R.screens })
end)

local STEP = 50
local busy = false
local since_slow = 0
local since_pc = 0

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

    since_slow = since_slow + STEP
    if since_slow >= 1000 then
        since_slow = 0
        if C.reload() then P.reapply_camera() end
        R.read_screens()
        pcall(A.step)
        F.tick(A.done and I.host_present())
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
