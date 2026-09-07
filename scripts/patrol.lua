-- patrol.lua — spawns guards and walks them with coroutine tasks.
-- `state` survives a hot reload; everything else in this file does not.

local guards = state.guards
if not guards then
    guards = {}
    for i = 1, 3 do
        guards[i] = engine.spawn("guard", i * 4.0, 0.0)
    end
    state.guards = guards
    engine.log("spawned", #guards, "guards")
else
    engine.log("reload: reattaching to", #guards, "existing guards")
end

-- Tasks may block with engine.wait(); "update" handlers may not.
for i, id in ipairs(guards) do
    engine.spawn_task(function()
        local lane, period = i * 4.0, 0.4 + i * 0.1
        -- engine.hp returns nil once the entity is gone: the task ends itself
        while engine.hp(id) do
            engine.set_pos(id, lane, 6.0)
            engine.wait(period)
            if not engine.hp(id) then break end
            engine.set_pos(id, lane, -6.0)
            engine.wait(period)
        end
        engine.log(("patrol task for %d retired"):format(id))
    end)
end

engine.on("damage", function(id, amount)
    local hp = engine.hurt(id, amount)
    engine.log(("entity %d took %d damage -> hp %.0f"):format(id, amount, hp or 0))
end)

engine.on("death", function(id)
    engine.log(("entity %d died at t=%.2f"):format(id, engine.time()))
    for i, gid in ipairs(state.guards) do
        if gid == id then table.remove(state.guards, i) break end
    end
end)
