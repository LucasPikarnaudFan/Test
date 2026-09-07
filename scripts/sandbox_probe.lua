-- sandbox_probe.lua — proves what the sandbox denies. Delete in production.
local denied = { "io", "os", "debug", "package", "require",
                 "load", "loadstring", "dofile", "loadfile",
                 "collectgarbage", "print", "_G" }
for _, name in ipairs(denied) do
    assert(_ENV[name] == nil, name .. " leaked into the sandbox")
end
assert(getmetatable(_ENV) == "sandbox", "env metatable is reachable")
engine.log("sandbox ok:", #denied, "globals denied, engine api reachable")
