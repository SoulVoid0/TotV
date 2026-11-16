-- Performance settings that do not change what the player sees.
--
-- Always on (engine housekeeping, no visual effect):
--   * garbage collection destroys objects on worker threads and skips the forced
--     purge after level streaming, removing the multi-frame hitches VotV's large
--     world produces;
--   * texture streaming stays inside real VRAM (DXVK otherwise oversubscribes and
--     stutters);
--   * animation update/evaluation run in parallel;
--   * the shader pipeline cache is used (fewer first-sight shader hitches).
-- While the KDE desktop covers the screen (the player is at the in-game PC), the 3D
-- view is not visible at all, so the game renders it at reduced cost until the
-- player leaves the PC; the view is back to normal before the camera blend ends.
local U = require('util')
local C = require('config')

local F = { applied = false, hidden = false }

local ALWAYS = {
    'gc.MultithreadedDestructionEnabled 1',
    's.ForceGCAfterLevelStreamedOut 0',
    's.ContinuouslyIncrementalGCWhileLevelsPendingPurge 1',
    'r.Streaming.LimitPoolSizeToVRAM 1',
    'a.ParallelAnimUpdate 1',
    'a.ParallelAnimEvaluation 1',
    'r.ShaderPipelineCache.Enabled 1',
}

-- The player's own values are read before lowering and put back afterwards.
local HIDDEN = { { 't.MaxFPS', 30, 0 }, { 'r.ScreenPercentage', 50, 100 } }
local saved = {}

local function cvar(name, fallback)
    local ks = U.kismet_system()
    local v = ks and U.try(function() return ks:GetConsoleVariableFloatValue(name) end)
    if type(v) == 'number' then return v end
    return fallback
end

function F.tick(in_game)
    if not C.values.perf.enabled then return end
    if in_game and not F.applied then
        for _, cmd in ipairs(ALWAYS) do U.console(cmd) end
        F.applied = true
        U.log('perf: applied', #ALWAYS, 'engine settings')
    end
end

-- Called with true when the real KDE window has covered the game, false when the
-- player leaves the PC (before the overlay is lowered).
function F.set_hidden(hidden)
    if not C.values.perf.enabled or hidden == F.hidden then return end
    F.hidden = hidden
    for _, h in ipairs(HIDDEN) do
        local name, low, default = h[1], h[2], h[3]
        if hidden then
            saved[name] = cvar(name, default)
            local target = low
            if name == 't.MaxFPS' and saved[name] > 0 then target = math.min(low, saved[name]) end
            if name == 'r.ScreenPercentage' then target = math.min(low, saved[name]) end
            U.console(name .. ' ' .. target)
        else
            U.console(name .. ' ' .. (saved[name] or default))
        end
    end
end

return F
