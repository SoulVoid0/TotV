-- Generic UMG mirroring: walk a live widget tree into a flat, serialisable list
-- (type, text, state, rectangle relative to the root), and perform actions on
-- an entry by id. The KDE relay app and the second-screen inventory render the
-- list and send the actions back. Nothing here is specific to one game screen,
-- so every tab of the in-game PC is covered, including ones added by updates.
--
-- Clicks go through the game's own handlers: a UMG button bound in a Blueprint
-- compiles to a function on its owning widget named
--   BndEvt__<owner>_<button>_K2Node_ComponentBoundEvent_<n>_OnButtonClickedEvent__DelegateSignature
-- and calling it is exactly what a mouse click does.
local U = require('util')

local M = {}

local ESlateVisibility = { Visible = 0, Collapsed = 1, Hidden = 2, HitTestInvisible = 3, SelfHitTestInvisible = 4 }
M.ESlateVisibility = ESlateVisibility

local class_cache = {}
local function uclass(path)
    local c = class_cache[path]
    if U.valid(c) then return c end
    c = StaticFindObject(path)
    class_cache[path] = c
    return U.valid(c) and c or nil
end

local function isa(w, path)
    local c = uclass(path)
    if not c then return false end
    return U.try(function() return w:IsA(c) end) == true
end

local KINDS = {
    { '/Script/UMG.Button', 'button' },
    { '/Script/UMG.CheckBox', 'checkbox' },
    { '/Script/UMG.EditableTextBox', 'edit' },
    { '/Script/UMG.EditableText', 'edit' },
    { '/Script/UMG.MultiLineEditableTextBox', 'edit' },
    { '/Script/UMG.MultiLineEditableText', 'edit' },
    { '/Script/UMG.Slider', 'slider' },
    { '/Script/UMG.ProgressBar', 'progress' },
    { '/Script/UMG.ComboBoxString', 'combo' },
    { '/Script/UMG.TextBlock', 'text' },
    { '/Script/UMG.RichTextBlock', 'text' },
    { '/Script/UMG.ScrollBox', 'scroll' },
    { '/Script/UMG.WidgetSwitcher', 'switcher' },
    { '/Script/UMG.Image', 'image' },
    { '/Script/UMG.Border', 'border' },
}

local function kind_of(w)
    for _, k in ipairs(KINDS) do
        if isa(w, k[1]) then return k[2] end
    end
    return 'panel'
end

local function rect(w)
    local sl = U.slate_lib()
    if not sl then return nil end
    local g = U.try(function() return w:GetCachedGeometry() end)
    if not g then return nil end
    local pos = U.try(function() return sl:LocalToAbsolute(g, { X = 0, Y = 0 }) end)
    local size = U.try(function() return sl:GetAbsoluteSize(g) end)
    if not (pos and size) then return nil end
    return pos.X, pos.Y, size.X, size.Y
end

local function visible(w)
    local v = U.try(function() return w:IsVisible() end)
    if v == false then return false end
    local vis = U.try(function() return w:GetVisibility() end)
    return vis ~= ESlateVisibility.Collapsed and vis ~= ESlateVisibility.Hidden
end

local function text_of(w)
    local t = U.try(function() return w:GetText() end)
    if t == nil then return nil end
    return U.to_str(t)
end

-- Walk ---------------------------------------------------------------------------
-- registry: id -> { widget = UWidget, owner = UUserWidget, kind = string }
M.registry = {}

local MAX_ITEMS = 1500

local function walk(w, owner, id, out, origin, depth, skip)
    if #out >= MAX_ITEMS or depth > 40 then return end
    if not U.valid(w) or not visible(w) then return end
    if skip and skip[U.addr(w)] then return end
    local kind = kind_of(w)
    local x, y, ww, hh = rect(w)
    local is_user = isa(w, '/Script/UMG.UserWidget')
    if x and kind ~= 'panel' and kind ~= 'border' and not is_user then
        local e = { id = id, kind = kind, name = U.obj_name(w),
                    x = x - origin.x, y = y - origin.y, w = ww, h = hh }
        if kind == 'text' or kind == 'edit' then e.text = text_of(w) end
        if kind == 'button' or kind == 'checkbox' or kind == 'slider' or kind == 'edit' then
            e.enabled = U.try(function() return w:GetIsEnabled() end) ~= false
        end
        if kind == 'checkbox' then e.checked = U.try(function() return w:IsChecked() end) == true end
        if kind == 'slider' then e.value = U.try(function() return w:GetValue() end) end
        if kind == 'progress' then e.value = U.try(function() return w.Percent end) end
        if kind == 'combo' then e.text = U.to_str(U.try(function() return w:GetSelectedOption() end)) end
        if kind == 'scroll' then e.offset = U.try(function() return w:GetScrollOffset() end) end
        if kind == 'switcher' then e.index = U.try(function() return w:GetActiveWidgetIndex() end) end
        if kind == 'image' then
            local c = U.try(function() return w.ColorAndOpacity end)
            if c then e.color = { c.R, c.G, c.B, c.A } end
        end
        out[#out + 1] = e
        M.registry[id] = { widget = w, owner = owner, kind = kind }
    end
    if is_user then
        local tree = U.try(function() return w.WidgetTree end)
        local root = tree and U.try(function() return tree.RootWidget end)
        if U.valid(root) then walk(root, w, id .. '/u', out, origin, depth + 1, skip) end
        return
    end
    if kind == 'switcher' then
        -- Only the visible page of a switcher.
        local child = U.try(function() return w:GetActiveWidget() end)
        if U.valid(child) then walk(child, owner, id .. '/a', out, origin, depth + 1, skip) end
        return
    end
    local n = U.try(function() return w:GetChildrenCount() end)
    if n and n > 0 then
        for i = 0, n - 1 do
            local child = U.try(function() return w:GetChildAt(i) end)
            if U.valid(child) then walk(child, owner, id .. '/' .. i, out, origin, depth + 1, skip) end
        end
    end
end

-- Snapshot of a UUserWidget. `skip` is a set of widget addresses to leave out
-- (the KDE overlay the mod adds on top of the laptop UI).
function M.snapshot(root_user_widget, skip)
    M.registry = {}
    local out = {}
    local x, y, w, h = rect(root_user_widget)
    local origin = { x = x or 0, y = y or 0 }
    walk(root_user_widget, root_user_widget, 'r', out, origin, 0, skip)
    return { width = w or 0, height = h or 0, items = out }
end

-- Actions -----------------------------------------------------------------------
local function bound_event(owner, widget_name, needles)
    return U.find_function_name(owner, 'bnd|' .. widget_name .. '|' .. table.concat(needles, ','), function(n)
        if not n:find('^BndEvt__') then return false end
        if not n:find('_' .. widget_name .. '_K2Node', 1, true) then return false end
        for _, needle in ipairs(needles) do
            if n:find(needle, 1, true) then return true end
        end
        return false
    end)
end

local function call_named(owner, fname, ...)
    if not fname then return false end
    local args = { ... }
    return U.try(function()
        local f = owner[fname]
        f(owner, table.unpack(args))
        return true
    end) == true
end

function M.click(id)
    local r = M.registry[id]
    if not r or not U.valid(r.widget) then return false, 'stale id' end
    local name = U.obj_name(r.widget)
    if r.kind == 'button' then
        if U.try(function() return r.widget:GetIsEnabled() end) == false then return false, 'disabled' end
        local pressed = bound_event(r.owner, name, { 'OnButtonPressedEvent' })
        local released = bound_event(r.owner, name, { 'OnButtonReleasedEvent' })
        local clicked = bound_event(r.owner, name, { 'OnButtonClickedEvent' })
        if not (pressed or released or clicked) then return false, 'no handler' end
        if pressed then call_named(r.owner, pressed) end
        if released then call_named(r.owner, released) end
        if clicked then call_named(r.owner, clicked) end
        return true
    elseif r.kind == 'checkbox' then
        local now = not (U.try(function() return r.widget:IsChecked() end) == true)
        U.try(function() r.widget:SetIsChecked(now) end)
        call_named(r.owner, bound_event(r.owner, name, { 'OnCheckBoxComponentStateChanged' }), now)
        return true
    end
    return false, 'not clickable'
end

function M.set_text(id, text, commit)
    local r = M.registry[id]
    if not r or not U.valid(r.widget) or r.kind ~= 'edit' then return false, 'not an edit box' end
    local ft = FText(text or '')
    U.try(function() r.widget:SetText(ft) end)
    local name = U.obj_name(r.widget)
    call_named(r.owner, bound_event(r.owner, name, { 'TextChangedEvent', 'OnEditableTextBoxChanged', 'OnEditableTextChanged' }), ft)
    if commit then
        -- ETextCommit::OnEnter == 1
        call_named(r.owner, bound_event(r.owner, name, { 'TextCommittedEvent', 'CommittedEvent' }), ft, 1)
    end
    return true
end

function M.set_value(id, value)
    local r = M.registry[id]
    if not r or not U.valid(r.widget) then return false, 'stale id' end
    if r.kind == 'slider' then
        U.try(function() r.widget:SetValue(value) end)
        call_named(r.owner, bound_event(r.owner, U.obj_name(r.widget), { 'OnFloatValueChangedEvent' }), value)
        return true
    elseif r.kind == 'combo' then
        U.try(function() r.widget:SetSelectedOption(tostring(value)) end)
        call_named(r.owner, bound_event(r.owner, U.obj_name(r.widget), { 'OnSelectionChangedEvent' }), tostring(value), 0)
        return true
    elseif r.kind == 'scroll' then
        U.try(function() r.widget:SetScrollOffset(tonumber(value) or 0) end)
        return true
    end
    return false, 'not settable'
end

function M.widget_of(id)
    local r = M.registry[id]
    return r and r.widget
end

return M
