# Test — embedded Lua script runner for a game engine

A sandboxed Lua 5.4 scripting runtime a game engine can host: gameplay logic
lives in `.lua` files, the engine injects its C API into each script, and the
files reload while the loop keeps running.

| File | Role |
|---|---|
| `script_host.h/.c` | the runtime: sandbox, event dispatch, coroutine scheduler, watchdog, hot reload |
| `demo_engine.c` | a stand-in engine (entity table + fixed-step loop) and its bindings |
| `scripts/*.lua` | example gameplay scripts |
| `demos/runaway.lua` | infinite loop, loaded on purpose to prove the watchdog |

## Build & run

```sh
make            # needs liblua5.4-dev (the language itself; nothing else)
make run        # 240 ticks @ 60 Hz, then the watchdog check
./demo_engine scripts --realtime   # edit scripts/ live and watch them reload
```

## Guarantees

* **Sandbox** — each script runs in its own `_ENV` whose `__index` is a
  whitelisted table. `io`, `os`, `debug`, `package`, `require`, `load`,
  `dofile`, `loadfile` and `_G` are never reachable; `luaL_loadbufferx(..., "t")`
  refuses precompiled bytecode. `scripts/sandbox_probe.lua` asserts all of it.
* **Memory cap** — custom `lua_Alloc` returns `NULL` past `mem_limit`, so the
  VM raises a normal Lua error instead of taking the process down.
* **Instruction budget** — a `LUA_MASKCOUNT` hook kills a script that burns
  more than `step_budget` VM instructions in one dispatch, so a `while true do
  end` costs one frame, not the game.
* **Errors are local** — every entry point goes through `lua_pcall` with a
  traceback handler; a broken script is logged and unloaded, the loop lives on.
* **Hot reload** — `mtime` scan every `reload_period` seconds. Handlers and
  tasks of the old version are purged, the script's `state` table is carried
  over, so entities are not respawned on reload.

## Script API

```lua
engine.log(...)                  -- routed to the host logger
engine.time()  engine.dt()
engine.on(event, fn)             -- "update", "damage", "death", any sh_emit name
engine.spawn_task(fn, ...)       -- coroutine; only tasks may block
engine.wait(seconds)             -- yields, returns seconds actually elapsed
state                            -- per-script table, survives hot reload
```

Game-specific bindings are added from C with `sh_register(h, luaL_Reg[])`;
the demo adds `spawn`, `destroy`, `pos`, `set_pos`, `hp`, `hurt`, `each`.
