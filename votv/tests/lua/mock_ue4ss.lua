-- A small stand-in for the UE4SS Lua API, enough to run the TotVOS mod logic
-- outside the game: objects, classes with inheritance, FindFirstOf/FindAllOf,
-- StaticFindObject, FName/FText and the async helpers.
local Mock = { objects = {}, calls = {}, console = {}, next_addr = 0x1000 }

local function fname(s) return { ToString = function() return s end, s = s } end
_G.FName = function(s) return fname(s) end
_G.FText = function(s) return fname(s) end

local classes = {}
function Mock.class(name, super)
    local c = { __name = name, __super = super and classes[super] or nil }
    c.GetFName = function() return fname(name) end
    c.IsValid = function() return true end
    c.GetAddress = function() return 0 end
    c.GetSuperStruct = function() return c.__super end
    c.ForEachFunction = function(self, cb)
        for k, v in pairs(c.__functions or {}) do if cb({ GetFName = function() return fname(k) end }) then return end end
    end
    classes[name] = c
    return c
end

local function is_a(cls, target)
    while cls do
        if cls == target then return true end
        cls = cls.__super
    end
    return false
end

function Mock.new(class_name, props)
    local cls = classes[class_name] or Mock.class(class_name)
    Mock.next_addr = Mock.next_addr + 0x10
    local o = props or {}
    local addr = Mock.next_addr
    o.__class = cls
    o.IsValid = o.IsValid or function() return true end
    o.GetAddress = function() return addr end
    o.GetClass = function() return cls end
    o.GetFName = o.GetFName or function() return fname(o.__name or class_name .. '_' .. addr) end
    o.IsA = function(self, c) return is_a(cls, c) end
    for k, v in pairs(cls.__functions or {}) do
        if o[k] == nil then o[k] = v end
    end
    Mock.objects[#Mock.objects + 1] = o
    return o
end

local function by_class(name)
    local out = {}
    for _, o in ipairs(Mock.objects) do
        local c = o.__class
        while c do
            if c.__name == name then out[#out + 1] = o; break end
            c = c.__super
        end
    end
    return out
end

_G.FindFirstOf = function(name) return by_class(name)[1] or { IsValid = function() return false end } end
_G.FindAllOf = function(name) local l = by_class(name); return #l > 0 and l or nil end
_G.FindObject = function() return nil end
_G.ForEachUObject = function(cb) for _, o in ipairs(Mock.objects) do cb(o) end end
_G.StaticFindObject = function(path)
    local short = path:match('%.([%w_]+)$') or path
    if short:find('^Default__') then return by_class(short:gsub('^Default__', ''))[1] end
    return classes[short]
end
_G.StaticConstructObject = function(cls, outer, name)
    return Mock.new(cls.__name, { __name = name and name.s })
end
_G.ExecuteInGameThread = function(fn) fn() end
_G.LoopAsync = function(ms, fn) Mock.loop = fn end
_G.ExecuteWithDelay = function(ms, fn) fn() end

-- Engine library CDOs.
Mock.class('Object')
Mock.class('KismetSystemLibrary', 'Object')
Mock.new('KismetSystemLibrary', {
    ExecuteConsoleCommand = function(self, world, cmd) Mock.console[#Mock.console + 1] = cmd end,
    GetConsoleVariableFloatValue = function(self, name) return name == 'r.ScreenPercentage' and 80 or 0 end,
})
Mock.class('KismetRenderingLibrary', 'Object')
Mock.new('KismetRenderingLibrary', {
    ImportFileAsTexture2D = function(self, w, path)
        Mock.imported = path
        return Mock.new('Texture2D')
    end,
})
Mock.class('KismetMathLibrary', 'Object')
Mock.new('KismetMathLibrary', {
    TransformLocation = function(self, xf, p) return { X = xf.X + p.X, Y = xf.Y + p.Y, Z = xf.Z + p.Z } end,
    FindLookAtRotation = function() return { Pitch = 0, Yaw = 180, Roll = 0 } end,
})
Mock.class('SlateBlueprintLibrary', 'Object')
Mock.new('SlateBlueprintLibrary', {
    LocalToAbsolute = function(self, g, p) return { X = g.x + p.X, Y = g.y + p.Y } end,
    GetAbsoluteSize = function(self, g) return { X = g.w, Y = g.h } end,
})
Mock.class('GameplayStatics', 'Object')
Mock.saves = {}
Mock.new('GameplayStatics', {
    DoesSaveGameExist = function(self, slot) return Mock.saves[slot] ~= nil end,
    LoadGameFromSlot = function(self, slot) return Mock.saves[slot] end,
    CreateSaveGameObject = function(self, cls)
        return Mock.new('saveSlot_C', { localGameRules = { difficulty = 0 }, savedtime = { X = 0, Y = 0, Z = 1 } })
    end,
    SaveGameToSlot = function(self, save, slot) Mock.saves[slot] = save; return true end,
})
Mock.class('World', 'Object')
Mock.new('World', { SpawnActor = function(self, cls, pos, rot) return Mock.new('CameraActor', { CameraComponent = Mock.new('CameraComponent', { SetFieldOfView = function() end }), K2_SetActorLocationAndRotation = function() end }) end })

-- UMG classes.
for _, n in ipairs({ 'Widget', 'PanelWidget', 'UserWidget', 'CanvasPanel', 'Button', 'TextBlock', 'EditableTextBox',
                     'Image', 'WidgetSwitcher', 'CheckBox', 'Slider', 'ProgressBar', 'ScrollBox', 'Border',
                     'ComboBoxString', 'EditableText', 'MultiLineEditableTextBox', 'MultiLineEditableText', 'RichTextBlock',
                     'CameraActor', 'WidgetComponent', 'PlayerController', 'WidgetInteractionComponent' }) do
    Mock.class(n)
end
classes.PanelWidget.__super = classes.Widget
classes.UserWidget.__super = classes.Widget
classes.CanvasPanel.__super = classes.PanelWidget
classes.Button.__super = classes.PanelWidget
classes.Border.__super = classes.PanelWidget
classes.WidgetSwitcher.__super = classes.PanelWidget
classes.ScrollBox.__super = classes.PanelWidget
for _, n in ipairs({ 'TextBlock', 'EditableTextBox', 'Image', 'CheckBox', 'Slider', 'ProgressBar' }) do
    classes[n].__super = classes.Widget
end

Mock.classes = classes
return Mock
