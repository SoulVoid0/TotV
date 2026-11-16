-- Runs the TotVOS mod against the mock UE4SS API.
--   VOTV_OS_RUNTIME=<dir> VOTV_OS_USERCONF=<file> lua5.4 test_mod.lua <mod Scripts dir>
local scripts = assert(arg[1], 'usage: test_mod.lua <Scripts dir>')
package.path = scripts .. '/?.lua;' .. arg[0]:gsub('[^/]+$', '') .. '?.lua;' .. package.path
local Mock = require('mock_ue4ss')
local json = require('json')
local RT = os.getenv('VOTV_OS_RUNTIME')

local failures = 0
local function check(cond, what)
    if cond then print('ok   ' .. what) else print('FAIL ' .. what); failures = failures + 1 end
end
local function read(name)
    local f = io.open(RT .. '/' .. name, 'rb'); if not f then return nil end
    local s = f:read('a'); f:close(); return s
end
local function write(name, s)
    local f = assert(io.open(RT .. '/' .. name, 'wb')); f:write(s); f:close()
end
local function events()
    local out = {}
    for line in (read('game-events.jsonl') or ''):gmatch('[^\n]+') do out[#out + 1] = json.decode(line) end
    return out
end
local function has_event(kind, pred)
    for _, e in ipairs(events()) do if e.type == kind and (not pred or pred(e)) then return true end end
    return false
end
local function command(t)
    local f = assert(io.open(RT .. '/host-commands.jsonl', 'ab')); f:write(json.encode(t) .. '\n'); f:close()
end
local function run(ms) for _ = 1, ms // 50 do Mock.loop() end end

-- The menu world ----------------------------------------------------------------------
local fstr = function(s) return { ToString = function() return s end } end
Mock.class('mainGameInstance_C')
local gi = Mock.new('mainGameInstance_C', { gameRules = { difficulty = 2 }, loadObjects = false, GameMode = 9,
    setSaveSlotObject = function(self, save, slot) self.registered = slot end })
Mock.class('ui_saveSlots_C', 'UserWidget')
Mock.new('ui_saveSlots_C', { getSavePrefix = function(self, mode) return fstr(mode == 0 and 'story_' or 'other_') end })
Mock.class('saveSlot_C')
Mock.new('BlueprintGeneratedClass', { __name = 'saveSlot_C' })
Mock.new('PlayerController', { IsLocalPlayerController = function() return true end,
    GetWorld = function() return FindFirstOf('World') end,
    SetViewTargetWithBlend = function(self, t) Mock.view_target = t end,
    PlayerCameraManager = { GetFOVAngle = function() return 90 end, IsValid = function() return true end } })

require('main')
check(has_event('hello'), 'mod says hello on load')

run(1100)
check(gi.registered == 'story_Alice', 'autoload registers slot story_<SAVE_NAME> (got ' .. tostring(gi.registered) .. ')')
check(gi.loadObjects == true and gi.GameMode == 0, 'autoload sets loadObjects and the game mode')
check(Mock.saves['story_Alice'] ~= nil, 'a new save is written to its slot')
local opened = false
for _, c in ipairs(Mock.console) do if c == 'open untitled_1' then opened = true end end
check(opened, 'autoload opens the gameplay map')
check(has_event('autoload', function(e) return e.created == true end), 'autoload event reports a created save')

-- Gameplay world ----------------------------------------------------------------------------
local function text(name, s) return Mock.new('TextBlock', { __name = name, IsVisible = function() return true end,
    GetText = function() return fstr(s) end, GetCachedGeometry = function() return { x = 10, y = 20, w = 100, h = 20 } end }) end
local function button(name) return Mock.new('Button', { __name = name, IsVisible = function() return true end,
    GetIsEnabled = function() return true end, GetChildrenCount = function() return 0 end,
    GetCachedGeometry = function() return { x = 10, y = 50, w = 80, h = 30 } end }) end

local children = {}
local canvas = Mock.new('CanvasPanel', { IsVisible = function() return true end,
    GetChildrenCount = function() return #children end, GetChildAt = function(self, i) return children[i + 1] end,
    GetCachedGeometry = function() return { x = 0, y = 0, w = 800, h = 600 } end,
    AddChildToCanvas = function(self, w)
        children[#children + 1] = w
        return Mock.new('CanvasPanelSlot', { SetAnchors = function() end, SetOffsets = function() end, SetZOrder = function() end })
    end })
children[1] = text('title', 'Email')
children[2] = button('Button_tab_store')
Mock.class('ui_laptop_C', 'UserWidget')
Mock.classes.ui_laptop_C.__functions = {
    BndEvt__ui_laptop_Button_tab_store_K2Node_ComponentBoundEvent_7_OnButtonClickedEvent__DelegateSignature =
        function(self) Mock.store_clicked = true end,
}
local laptop = Mock.new('ui_laptop_C', { IsVisible = function() return true end,
    WidgetTree = { RootWidget = canvas },
    GetCachedGeometry = function() return { x = 0, y = 0, w = 800, h = 600 } end })

Mock.class('ui_playerInventory_C', 'UserWidget')
local inv_children = { text('item', 'Flashlight') }
local inv_root = Mock.new('CanvasPanel', { IsVisible = function() return true end,
    GetChildrenCount = function() return #inv_children end, GetChildAt = function(self, i) return inv_children[i + 1] end })
local inventory = Mock.new('ui_playerInventory_C', { IsVisible = function() return true end,
    WidgetTree = { RootWidget = inv_root },
    GetCachedGeometry = function() return { x = 0, y = 0, w = 600, h = 400 } end,
    SetRenderOpacity = function(self, v) self.opacity = v end, exit = function(self) Mock.inv_exit = true end })

Mock.class('mainPlayer_C')
local player = Mock.new('mainPlayer_C', { K2_GetActorLocation = function() return { X = 5000, Y = 0, Z = 0 } end })
Mock.class('mainGamemode_C')
Mock.new('mainGamemode_C', { mainPlayer = player, laptop = laptop, propInventory = inventory })
Mock.new('WidgetComponent', {
    GetUserWidgetObject = function() return laptop end,
    GetDrawSize = function() return { X = 100, Y = 60 } end, Pivot = { X = 0.5, Y = 0.5 },
    K2_GetComponentToWorld = function() return { X = 0, Y = 0, Z = 100 } end,
    GetForwardVector = function() return { X = 1, Y = 0, Z = 0 } end,
    GetRightVector = function() return { X = 0, Y = 1, Z = 0 } end,
    GetUpVector = function() return { X = 0, Y = 0, Z = 1 } end,
    K2_GetComponentScale = function() return { X = 1, Y = 1, Z = 1 } end })

write('screens.json', '{"screens":[{"name":"DP-1"}]}')   -- the bridge is running
run(1100)
check(has_event('in_game'), 'autoload notices gameplay')
local overlay = children[3]
check(overlay == nil, 'no overlay before the first KDE frame')

-- A frame from the host appears on the in-game screen.
os.execute('mkdir -p ' .. RT .. '/frames')
write('frames/pc-1.bmp', 'BM')
write('pc-frame.json', '{"seq":1,"file":"frames/pc-1.bmp","w":4,"h":4}')
run(600)
check(Mock.imported == RT .. '/frames/pc-1.bmp', 'frame imported as a texture (' .. tostring(Mock.imported) .. ')')
run(200)
overlay = children[3]
check(overlay ~= nil and overlay.__name == 'TotVOS_KDE', 'KDE overlay added to the laptop UI')

-- Using the PC.
player.activeInterface = laptop
run(200)
check(has_event('pc_active', function(e) return e.active == true end), 'pc_active sent when the laptop is in use')
check(Mock.view_target and Mock.view_target.__class.__name == 'CameraActor', 'camera moved to the screen')
command({ type = 'overlay_shown', shown = true })
run(100)
local low = false
for _, c in ipairs(Mock.console) do if c == 'r.ScreenPercentage 50' then low = true end end
check(low, 'game renders cheaper while hidden behind the KDE window')
command({ type = 'leave_pc' })
command({ type = 'overlay_shown', shown = false })
run(100)
check(has_event('pc_active', function(e) return e.active == false end), 'leave_pc returns to the game')
check(Mock.console[#Mock.console] == 'r.ScreenPercentage 80', "player's own resolution scale restored")
check(Mock.view_target == player, 'camera back on the player')

-- The relay app.
command({ type = 'relay_subscribe', on = true })
run(400)
local snap = json.decode(read('laptop-ui.json') or 'null')
check(snap and #snap.items >= 2, 'laptop UI mirrored for the relay app')
local btn_id
for _, it in ipairs(snap and snap.items or {}) do
    if it.kind == 'button' then btn_id = it.id end
    check(it.name ~= 'TotVOS_KDE', 'mirror leaves out the KDE overlay (' .. tostring(it.name) .. ')')
end
command({ type = 'relay_click', id = btn_id, req = 7 })
run(100)
check(Mock.store_clicked == true, "relay click runs the game's own button handler")
check(has_event('ack', function(e) return e.req == 7 and e.ok end), 'relay click acknowledged')

-- Second-screen inventory.
write('screens.json', '{"screens":[{"name":"DP-1"},{"name":"HDMI-A-1"}]}')
run(1100)
player.activeInterface = inventory
run(400)
check(inventory.opacity == 0.0, 'inventory hidden in the 3D view with two screens')
local isnap = json.decode(read('inventory-ui.json') or 'null')
check(isnap and isnap.items[1] and isnap.items[1].text == 'Flashlight', 'inventory mirrored for the second screen')
command({ type = 'inv_close' })
run(100)
check(Mock.inv_exit == true, "inventory closed through the game's own exit")
player.activeInterface = nil
run(200)
check(inventory.opacity == 1.0, 'inventory visible again after closing')

print(failures == 0 and 'ALL PASSED' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
