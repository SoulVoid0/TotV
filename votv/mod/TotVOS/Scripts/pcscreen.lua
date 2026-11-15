-- The in-game PC becomes the KDE Plasma desktop.
--
-- * From afar: every ui_laptop_C (the base laptop and portable PCs) gets a full-size
--   Image on top of the game's own UI, showing frames of the KDE "PC" session that
--   the host bridge captures (pc-frame.json -> a BMP under the runtime dir).
-- * In use (mainPlayer_C.activeInterface is a ui_laptop_C): the camera moves to a
--   player-calibrated pose in front of the laptop's screen so the in-game screen lines
--   up with the real monitor, and the host raises the live KDE session window over it
--   at native resolution and frame rate. Leaving (Meta+Esc, or the game closing the
--   interface) blends the camera back.
local U = require('util')
local C = require('config')
local I = require('ipc')

local P = { using = false, overlays = {}, texture = nil, frame_seq = -1, cam = nil,
            using_widget = nil, suppressed_for = 0 }

local OVERLAY_NAME = 'TotVOS_KDE'
local last_frame_at = -100000

local function is_laptop_ui(w)
    if not U.valid(w) then return false end
    local cn = U.class_name(w)
    return cn == 'ui_laptop_C' or cn:find('^ui_laptop') ~= nil
end

local function active_interface()
    local p = U.main_player()
    if not p then return nil end
    local w = U.try(function() return p.activeInterface end)
    if U.valid(w) then return w end
    return nil
end

-- Overlay ------------------------------------------------------------------------
local function make_overlay(ui)
    local tree = U.try(function() return ui.WidgetTree end)
    local root = tree and U.try(function() return tree.RootWidget end)
    if not U.valid(root) then return nil end
    local img_cls = StaticFindObject('/Script/UMG.Image')
    local img = U.try(StaticConstructObject, img_cls, tree, FName(OVERLAY_NAME))
    if not U.valid(img) then
        img = U.try(StaticConstructObject, img_cls, tree)
    end
    if not U.valid(img) then U.warn_once('overlay-construct', 'pc: could not construct overlay Image'); return nil end

    local canvas_cls = StaticFindObject('/Script/UMG.CanvasPanel')
    local slot
    if U.valid(canvas_cls) and U.try(function() return root:IsA(canvas_cls) end) then
        slot = U.try(function() return root:AddChildToCanvas(img) end)
        if U.valid(slot) then
            U.try(function() slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 1, Y = 1 } }) end)
            U.try(function() slot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 }) end)
            U.try(function() slot:SetZOrder(100000) end)
        end
    else
        slot = U.try(function() return root:AddChild(img) end)
        if U.valid(slot) then
            U.try(function() slot:SetHorizontalAlignment(3) end)  -- HAlign_Fill
            U.try(function() slot:SetVerticalAlignment(3) end)    -- VAlign_Fill
        end
    end
    if not U.valid(slot) then U.warn_once('overlay-slot', 'pc: laptop root is not a panel; overlay not added'); return nil end
    -- Clicks pass through to the game's own UI underneath (the relay app drives it).
    U.try(function() img:SetVisibility(3) end)
    U.try(function() img:SetColorAndOpacity({ R = 0.02, G = 0.02, B = 0.05, A = 1 }) end)
    return img
end

local function ensure_overlays()
    -- Only once the bridge has delivered a frame: never a blank screen over the game's UI.
    local want = C.values.pc.replace_ingame_ui and P.texture ~= nil
    for _, ui in ipairs(U.find_all('ui_laptop_C')) do
        local key = U.addr(ui)
        local entry = P.overlays[key]
        if not entry or not U.valid(entry.img) then
            if want then
                local img = make_overlay(ui)
                if img then
                    P.overlays[key] = { ui = ui, img = img }
                    if U.valid(P.texture) then
                        U.try(function() img:SetBrushFromTexture(P.texture, false) end)
                        U.try(function() img:SetColorAndOpacity({ R = 1, G = 1, B = 1, A = 1 }) end)
                    end
                end
            end
        else
            U.try(function() entry.img:SetVisibility(want and 3 or 1) end)
        end
    end
    for key, entry in pairs(P.overlays) do
        if not U.valid(entry.ui) then P.overlays[key] = nil end
    end
end

function P.overlay_addresses()
    local set = {}
    for _, e in pairs(P.overlays) do set[U.addr(e.img)] = true end
    return set
end

local function refresh_frame()
    if not C.values.pc.replace_ingame_ui or P.using then return end
    local fps = tonumber(C.values.pc.ingame_fps) or 2
    if fps <= 0 then return end
    if U.ticks() - last_frame_at < 1000 / fps then return end
    local meta = I.read_json('pc-frame.json')
    if type(meta) ~= 'table' or not meta.file or meta.seq == P.frame_seq then return end
    last_frame_at = U.ticks()
    local kr, w = U.kismet_render(), U.world()
    if not (kr and w) then return end
    local path = I.path(meta.file)
    local tex = U.try(function() return kr:ImportFileAsTexture2D(w, path) end)
    if not U.valid(tex) then return end
    P.texture = tex   -- the previous texture is released to the GC
    P.frame_seq = meta.seq
    for _, e in pairs(P.overlays) do
        U.try(function() e.img:SetBrushFromTexture(tex, false) end)
        U.try(function() e.img:SetColorAndOpacity({ R = 1, G = 1, B = 1, A = 1 }) end)
    end
end

-- Camera -------------------------------------------------------------------------
local function screen_component_for(ui)
    for _, comp in ipairs(U.find_all('WidgetComponent')) do
        local w = U.try(function() return comp:GetUserWidgetObject() end)
        if U.same(w, ui) then return comp end
    end
    return nil
end
P.screen_component_for = screen_component_for

local function vadd(a, b, s) return { X = a.X + b.X * s, Y = a.Y + b.Y * s, Z = a.Z + b.Z * s } end

-- World point on a widget component for normalised widget coords (u right, v down).
function P.widget_point(comp, u, v)
    local draw = U.try(function() return comp:GetDrawSize() end) or { X = 1, Y = 1 }
    local pivot = U.try(function() return comp.Pivot end) or { X = 0.5, Y = 0.5 }
    local km = U.kismet_math()
    local xf = U.try(function() return comp:K2_GetComponentToWorld() end)
    if not (km and xf) then return nil end
    -- UWidgetComponent maps component (-Y, -Z) to widget (x, y), offset by the pivot.
    local localp = { X = 0, Y = -(u - pivot.X) * draw.X, Z = -(v - pivot.Y) * draw.Y }
    return U.try(function() return km:TransformLocation(xf, localp) end)
end

local function camera_pose(comp)
    local cam = C.values.pc.camera
    local center = P.widget_point(comp, 0.5, 0.5)
    local fwd = U.try(function() return comp:GetForwardVector() end)
    local right = U.try(function() return comp:GetRightVector() end)
    local up = U.try(function() return comp:GetUpVector() end)
    local draw = U.try(function() return comp:GetDrawSize() end)
    local scale = U.try(function() return comp:K2_GetComponentScale() end) or { X = 1, Y = 1, Z = 1 }
    if not (center and fwd and right and up and draw) then return nil end
    local fov = tonumber(cam.fov) or 0
    if fov <= 0 then
        local pcm = U.try(function() return U.player_controller().PlayerCameraManager end)
        fov = (pcm and U.try(function() return pcm:GetFOVAngle() end)) or 90
    end
    local width = draw.X * math.abs(scale.Y)
    local dist = (width / 2) / math.tan(math.rad(fov) / 2) * (tonumber(cam.distance_scale) or 1)
    local pos = vadd(center, fwd, dist + (tonumber(cam.offset_forward) or 0))
    -- Widget right is component -Y.
    pos = vadd(pos, right, -(tonumber(cam.offset_right) or 0))
    pos = vadd(pos, up, tonumber(cam.offset_up) or 0)
    local km = U.kismet_math()
    local rot = U.try(function() return km:FindLookAtRotation(pos, center) end) or { Pitch = 0, Yaw = 0, Roll = 0 }
    rot = { Pitch = rot.Pitch + (tonumber(cam.pitch) or 0), Yaw = rot.Yaw + (tonumber(cam.yaw) or 0),
            Roll = rot.Roll + (tonumber(cam.roll) or 0) }
    return pos, rot, fov
end

local function ensure_camera(pos, rot, fov)
    if not U.valid(P.cam) then
        local w = U.world()
        local cls = StaticFindObject('/Script/Engine.CameraActor')
        P.cam = U.try(function() return w:SpawnActor(cls, pos, rot) end)
        if not U.valid(P.cam) then U.warn_once('cam', 'pc: could not spawn CameraActor'); return nil end
    end
    U.try(function() P.cam:K2_SetActorLocationAndRotation(pos, rot, false, {}, true) end)
    local cc = U.try(function() return P.cam.CameraComponent end)
    if U.valid(cc) then
        U.try(function() cc:SetFieldOfView(fov) end)
        U.try(function() cc.bConstrainAspectRatio = false end)
    end
    return P.cam
end

local function align_camera(ui)
    if not C.values.pc.align_camera or not I.host_present() then return false end
    local comp = screen_component_for(ui)
    if not comp then U.warn_once('nocomp', 'pc: no WidgetComponent shows the laptop UI'); return false end
    local pos, rot, fov = camera_pose(comp)
    if not pos then return false end
    local cam = ensure_camera(pos, rot, fov)
    local pc = U.player_controller()
    if not (cam and pc) then return false end
    U.try(function() pc:SetViewTargetWithBlend(cam, tonumber(C.values.pc.blend) or 0.35, 0, 0, false) end)
    return true
end

local function restore_camera()
    local pc, p = U.player_controller(), U.main_player()
    if pc and p then
        U.try(function() pc:SetViewTargetWithBlend(p, tonumber(C.values.pc.blend) or 0.35, 0, 0, false) end)
    end
end

local function enter(ui)
    if not I.host_present() then return end   -- vanilla behaviour without TotV OS
    P.using = true
    P.using_widget = ui
    local aligned = align_camera(ui)
    U.log('pc: in use (camera aligned:', aligned, ')')
    I.emit('pc_active', { active = true, aligned = aligned,
                          delay = aligned and (tonumber(C.values.pc.overlay_delay) or 0.4) or 0 })
end

local function leave(reason)
    if not P.using then return end
    P.using = false
    P.using_widget = nil
    restore_camera()
    U.log('pc: left (' .. reason .. ')')
    I.emit('pc_active', { active = false, reason = reason })
end

function P.leave_from_host()
    local ui = P.using_widget
    if not P.using then return end
    P.suppressed_for = U.addr(ui)
    -- Close the game's interface too when it has a verb for it; harmless if absent.
    local p = U.main_player()
    if p then U.try(function() p:setActiveInterface(nil) end) end
    leave('host')
end

-- Live calibration: the calibration app sets pc.camera.preview while open.
local function preview_tick()
    local cam = C.values.pc.camera
    if not cam.preview then return end
    local ui = P.using_widget or U.find_first('ui_laptop_C')
    if not ui then return end
    local comp = screen_component_for(ui)
    if not comp then return end
    local pos, rot, fov = camera_pose(comp)
    if pos then
        local c = ensure_camera(pos, rot, fov)
        local pc = U.player_controller()
        if c and pc then
            local vt = U.try(function() return pc:GetViewTarget() end)
            if not U.same(vt, c) then U.try(function() pc:SetViewTargetWithBlend(c, 0, 0, 0, false) end) end
        end
    end
end

local was_preview = false
function P.tick()
    ensure_overlays()
    local ai = active_interface()
    local laptop = is_laptop_ui(ai) and ai or nil
    if P.suppressed_for ~= 0 and U.addr(laptop) ~= P.suppressed_for then P.suppressed_for = 0 end
    if laptop and not P.using and P.suppressed_for == 0 then enter(laptop)
    elseif P.using and not laptop then leave('game')
    elseif P.using and C.values.pc.camera.preview then preview_tick() end
    local preview = C.values.pc.camera.preview == true
    if preview and not P.using then preview_tick() end
    if was_preview and not preview and not P.using then restore_camera() end
    was_preview = preview
    refresh_frame()
end

function P.reapply_camera()
    if P.using and P.using_widget then align_camera(P.using_widget) end
end

return P
