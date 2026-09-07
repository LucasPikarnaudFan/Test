-- spinner.lua — per-frame work in an "update" handler, state kept across reloads.
state.theta = state.theta or 0
state.id = state.id or engine.spawn("orb", 0, 0)

engine.on("update", function(dt)
    state.theta = (state.theta + dt * 2.0) % (2 * math.pi)
    engine.set_pos(state.id, 10 * math.cos(state.theta), 10 * math.sin(state.theta))
end)

engine.spawn_task(function()
    while true do
        local x, y = engine.pos(state.id)
        engine.log(("orb at %.2f, %.2f (%d entities live)")
                   :format(x, y, #engine.each()))
        engine.wait(1.0)
    end
end)
