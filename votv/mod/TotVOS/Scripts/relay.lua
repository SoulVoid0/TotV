-- Relays for the host apps:
--   * "VotV PC" (KDE app): the game's own laptop UI (ui_laptop_C), which the KDE
--     desktop covers in-game, mirrored and driven remotely: every tab, button, text
--     field, slider and list.
--   * Second-screen inventory: the game's inventory screen (mainGamemode_C.propInventory,
--     a ui_playerInventory_C) is hidden in the 3D view and mirrored to the inventory app
--     on another monitor when the player has 2+ screens.
local U = require('util')
local C = require('config')
local I = require('ipc')
local M = require('widgetmirror')
local P = require('pcscreen')

local R = { subscribed = false, last_snap = -100000, inv_open = false, inv_widget = nil,
            screens = 1, pending = {} }

-- Which mirror the registry ids currently belong to: snapshots of the two
-- screens alternate, so each keeps its own registry.
local registries = { laptop = {}, inventory = {} }

local function with_registry(which, fn, ...)
    M.registry = registries[which]
    local a, b = fn(...)
    registries[which] = M.registry
    return a, b
end

local function laptop_ui()
    local gm = U.gamemode()
    local ui = gm and U.try(function() return gm.laptop end)
    if U.valid(ui) then return ui end
    return U.find_first('ui_laptop_C')
end

local function snapshot(which, ui, file, extra)
    M.registry = {}
    local snap = M.snapshot(ui, which == 'laptop' and P.overlay_addresses() or nil)
    registries[which] = M.registry
    snap.seq = (R[which .. '_seq'] or 0) + 1
    R[which .. '_seq'] = snap.seq
    if extra then for k, v in pairs(extra) do snap[k] = v end end
    I.snapshot(file, snap)
end

-- Pointer taps on in-world widgets (anything that is not a bound button), through
-- the player's own WidgetInteractionComponent pointed at the laptop screen.
local function player_interaction()
    local p = U.main_player()
    for _, wic in ipairs(U.find_all('WidgetInteractionComponent')) do
        local owner = U.try(function() return wic:GetOwner() end)
        if U.same(owner, p) then return wic end
    end
    return nil
end

local function queue_tap(ui, u, v)
    local comp = P.screen_component_for(ui)
    local wic = player_interaction()
    if not (comp and wic) then return false end
    local pt = P.widget_point(comp, u, v)
    local fwd = U.try(function() return comp:GetForwardVector() end)
    if not pt then return false end
    local old = U.try(function() return wic.InteractionSource end)
    local hit = { bBlockingHit = true, Location = pt, ImpactPoint = pt, Normal = fwd, ImpactNormal = fwd,
                  Distance = 10.0, Component = comp, Actor = U.try(function() return comp:GetOwner() end) }
    local key = { KeyName = FName('LeftMouseButton') }
    R.pending[#R.pending + 1] = function() U.try(function() wic.InteractionSource = 3 end); U.try(function() wic:SetCustomHitResult(hit) end) end
    R.pending[#R.pending + 1] = function() U.try(function() wic:SetCustomHitResult(hit) end); U.try(function() wic:PressPointerKey(key) end) end
    R.pending[#R.pending + 1] = function() U.try(function() wic:ReleasePointerKey(key) end) end
    R.pending[#R.pending + 1] = function() if old ~= nil then U.try(function() wic.InteractionSource = old end) end end
    return true
end

local function queue_chars(text)
    local wic = player_interaction()
    if not wic then return false end
    R.pending[#R.pending + 1] = function() U.try(function() wic:SendKeyChar(text, false) end) end
    return true
end

local function ack(kind, msg, ok, err)
    I.emit('ack', { of = kind, req = msg.req, ok = ok == true, error = err })
end

-- Commands from the apps ----------------------------------------------------------
I.on('relay_subscribe', function(msg) R.subscribed = msg.on ~= false end)

I.on('relay_click', function(msg) local ok, e = with_registry('laptop', M.click, msg.id); ack('relay_click', msg, ok, e) end)
I.on('relay_text', function(msg) local ok, e = with_registry('laptop', M.set_text, msg.id, msg.text, msg.commit); ack('relay_text', msg, ok, e) end)
I.on('relay_value', function(msg) local ok, e = with_registry('laptop', M.set_value, msg.id, msg.value); ack('relay_value', msg, ok, e) end)
I.on('relay_tap', function(msg)
    local ui = laptop_ui()
    ack('relay_tap', msg, ui and queue_tap(ui, tonumber(msg.u) or 0, tonumber(msg.v) or 0), ui and nil or 'no laptop')
end)
I.on('relay_chars', function(msg) ack('relay_chars', msg, queue_chars(tostring(msg.text or ''))) end)
I.on('relay_tab', function(msg)
    local ui = laptop_ui()
    local sw = ui and U.try(function() return ui.switcher end)
    local ok = U.valid(sw) and U.try(function() sw:SetActiveWidgetIndex(tonumber(msg.index) or 0); return true end)
    if ok then U.try(function() ui:switcherSwitched() end) end
    ack('relay_tab', msg, ok)
end)

I.on('inv_click', function(msg) local ok, e = with_registry('inventory', M.click, msg.id); ack('inv_click', msg, ok, e) end)
I.on('inv_text', function(msg) local ok, e = with_registry('inventory', M.set_text, msg.id, msg.text, msg.commit); ack('inv_text', msg, ok, e) end)
I.on('inv_value', function(msg) local ok, e = with_registry('inventory', M.set_value, msg.id, msg.value); ack('inv_value', msg, ok, e) end)
I.on('inv_close', function(msg)
    local w = R.inv_widget
    local ok = U.valid(w) and U.try(function() w:exit(); return true end)
    ack('inv_close', msg, ok)
end)

-- Screens ---------------------------------------------------------------------------
local function second_screen_enabled()
    local mode = C.values.inventory.second_screen
    if mode == 'off' or mode == false then return false end
    if mode == 'on' or mode == true then return true end
    return R.screens >= 2
end

function R.read_screens()
    local s = I.read_json('screens.json')
    if type(s) == 'table' and type(s.screens) == 'table' then R.screens = #s.screens end
end

local function inventory_tick(snap_due)
    local gm, p = U.gamemode(), U.main_player()
    local screen = gm and U.try(function() return gm.propInventory end)
    local ai = p and U.try(function() return p.activeInterface end)
    local open = U.valid(screen) and U.same(ai, screen)
    local mirror = open and second_screen_enabled()
    if mirror and not R.inv_open then
        R.inv_open = true
        R.inv_widget = screen
        U.try(function() screen:SetRenderOpacity(0.0) end)
        I.emit('inventory', { open = true })
        snap_due = true
    elseif R.inv_open and not mirror then
        R.inv_open = false
        if U.valid(R.inv_widget) then U.try(function() R.inv_widget:SetRenderOpacity(1.0) end) end
        R.inv_widget = nil
        I.emit('inventory', { open = false })
    end
    if R.inv_open and snap_due then snapshot('inventory', screen, 'inventory-ui.json') end
end

function R.tick()
    if #R.pending > 0 then
        local fn = table.remove(R.pending, 1)
        pcall(fn)
    end
    local hz = tonumber(C.values.relay.snapshot_hz) or 4
    local due = U.ticks() - R.last_snap >= 1000 / math.max(hz, 0.5)
    if due then R.last_snap = U.ticks() end
    if R.subscribed and due then
        local ui = laptop_ui()
        if ui then
            local gm = U.gamemode()
            local points = gm and U.try(function() return gm.saveSlot.points end)
            snapshot('laptop', ui, 'laptop-ui.json', { points = points })
        end
    end
    inventory_tick(due)
end

return R
