-- Shared helpers: logging, files, and safe access to VotV 0.9.0n game objects.
-- Every engine call is wrapped so a renamed function in a future game build
-- disables one feature with a log line instead of breaking the game.
local U = {}

U.TAG = '[TotVOS] '

function U.log(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print(U.TAG .. table.concat(parts, ' ') .. '\n')
end

-- Log once per key, so a failing poll does not flood UE4SS.log.
local logged = {}
function U.warn_once(key, ...)
    if logged[key] then return end
    logged[key] = true
    U.log('WARN', ...)
end

function U.try(fn, ...)
    local ok, a, b, c = pcall(fn, ...)
    if ok then return a, b, c end
    return nil
end

function U.valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

function U.addr(o)
    if not U.valid(o) then return 0 end
    return U.try(function() return o:GetAddress() end) or 0
end

function U.same(a, b)
    local x = U.addr(a)
    return x ~= 0 and x == U.addr(b)
end

function U.class_name(o)
    if not U.valid(o) then return '' end
    return U.try(function() return o:GetClass():GetFName():ToString() end) or ''
end

function U.obj_name(o)
    if not U.valid(o) then return '' end
    return U.try(function() return o:GetFName():ToString() end) or ''
end

function U.now_ms()
    return math.floor(os.clock() * 1000)
end

-- Wall clock in ms (os.clock is CPU time; good enough for throttles within one frame
-- loop, but intervals across seconds use os.time + a monotonic counter below).
local tick_ms = 0
function U.advance(ms) tick_ms = tick_ms + ms end
function U.ticks() return tick_ms end

-- Files ---------------------------------------------------------------------
function U.read_file(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

-- Windows rename() refuses to replace an existing file, so remove first. The
-- host side treats a missing/partial file as "try again next poll".
function U.write_file_atomic(path, data)
    local tmp = path .. '.tmp'
    local f = io.open(tmp, 'wb')
    if not f then return false end
    f:write(data)
    f:close()
    os.remove(path)
    return os.rename(tmp, path) ~= nil
end

function U.append_file(path, data)
    local f = io.open(path, 'ab')
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

function U.file_size(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local n = f:seek('end')
    f:close()
    return n
end

-- Engine access ---------------------------------------------------------------
local cdo_cache = {}
function U.cdo(path)
    local o = cdo_cache[path]
    if U.valid(o) then return o end
    o = StaticFindObject(path)
    if U.valid(o) then cdo_cache[path] = o; return o end
    return nil
end

function U.statics() return U.cdo('/Script/Engine.Default__GameplayStatics') end
function U.kismet_system() return U.cdo('/Script/Engine.Default__KismetSystemLibrary') end
function U.kismet_math() return U.cdo('/Script/Engine.Default__KismetMathLibrary') end
function U.kismet_render() return U.cdo('/Script/Engine.Default__KismetRenderingLibrary') end
function U.slate_lib() return U.cdo('/Script/UMG.Default__SlateBlueprintLibrary') end

function U.find_first(cls)
    local o = U.try(FindFirstOf, cls)
    if U.valid(o) then return o end
    return nil
end

function U.find_all(cls)
    local list = U.try(FindAllOf, cls)
    local out = {}
    if list then
        for _, o in ipairs(list) do
            if U.valid(o) then out[#out + 1] = o end
        end
    end
    return out
end

function U.gamemode() return U.find_first('mainGamemode_C') end
function U.game_instance() return U.find_first('mainGameInstance_C') end

function U.player_controller()
    local pcs = U.find_all('PlayerController')
    for _, pc in ipairs(pcs) do
        local local_ok = U.try(function() return pc:IsLocalPlayerController() end)
        if local_ok ~= false then return pc end
    end
    return nil
end

function U.world()
    local pc = U.player_controller()
    if pc then
        local w = U.try(function() return pc:GetWorld() end)
        if U.valid(w) then return w end
    end
    return U.find_first('World')
end

function U.main_player()
    local gm = U.gamemode()
    if gm then
        local p = U.try(function() return gm.mainPlayer end)
        if U.valid(p) then return p end
    end
    return U.find_first('mainPlayer_C')
end

function U.console(cmd)
    local ks, w = U.kismet_system(), U.world()
    if not (ks and w) then return false end
    return U.try(function() ks:ExecuteConsoleCommand(w, cmd, nil); return true end) == true
end

-- A function on `obj` whose name satisfies `pred(name)`, searched through the
-- class hierarchy once and cached per class.
local fn_cache = {}
function U.find_function_name(obj, key, pred)
    local cls = U.try(function() return obj:GetClass() end)
    if not U.valid(cls) then return nil end
    local ck = U.addr(cls) .. '|' .. key
    if fn_cache[ck] ~= nil then return fn_cache[ck] or nil end
    local found = false
    local c = cls
    while U.valid(c) and not found do
        U.try(function()
            c:ForEachFunction(function(fn)
                local n = fn:GetFName():ToString()
                if not found and pred(n) then found = n; return true end
            end)
        end)
        c = U.try(function() return c:GetSuperStruct() end)
    end
    fn_cache[ck] = found
    return found or nil
end

-- Struct field by its short name: Blueprint structs suffix fields with a GUID
-- ("name_14_B381..."); this resolves "name" to the full field once per struct.
function U.field(struct_value, short)
    if struct_value == nil then return nil end
    local v = U.try(function() return struct_value[short] end)
    if v ~= nil then return v end
    local hit = nil
    U.try(function()
        struct_value:ForEachProperty(function(prop)
            local n = prop:GetFName():ToString()
            if n == short or n:find('^' .. short .. '_%d+_') then hit = n; return true end
        end)
    end)
    if hit then return U.try(function() return struct_value[hit] end) end
    return nil
end

function U.to_str(v)
    if v == nil then return '' end
    local t = type(v)
    if t == 'string' or t == 'number' or t == 'boolean' then return tostring(v) end
    local s = U.try(function() return v:ToString() end)
    return s or ''
end

return U
