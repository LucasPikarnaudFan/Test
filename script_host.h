/* script_host.h — embedded Lua scripting runtime for a game engine.
 *
 * The host owns one lua_State and injects the engine's C API into a set of
 * sandboxed script environments. Scripts cannot see the real _G, cannot load
 * bytecode, cannot touch io/os/debug/package, are capped in memory and in
 * instructions per dispatch, and are hot-reloadable while the loop runs.
 */
#ifndef SCRIPT_HOST_H
#define SCRIPT_HOST_H

#include <stddef.h>
#include <lua.h>
#include <lauxlib.h>

typedef struct sh_host sh_host;

typedef void (*sh_log_fn)(void *ud, const char *level, const char *msg);

typedef struct {
    void      *engine;       /* opaque game-side context handed to bindings  */
    size_t     mem_limit;    /* hard VM allocation cap in bytes, 0 = off     */
    long       step_budget;  /* VM instructions per dispatch, 0 = off        */
    double     reload_period;/* seconds between mtime scans, 0 = no hotload  */
    sh_log_fn  log;
    void      *log_ud;
} sh_config;

sh_host *sh_create(const sh_config *cfg);
void     sh_destroy(sh_host *h);

/* Loading. sh_load_file is also the reload path: reloading a known script
 * drops its handlers and tasks but carries its `state` table across. */
int  sh_load_file(sh_host *h, const char *path);
int  sh_load_dir (sh_host *h, const char *dir);
void sh_unload   (sh_host *h, const char *name);

/* Drive from the game loop. Runs hot-reload scan, "update" handlers, then
 * due coroutine tasks. */
void sh_tick(sh_host *h, double dt);

/* Fire a named event at script handlers. fmt: n=double i=int s=string b=bool.
 *   sh_emit(h, "damage", "ii", entity_id, amount); */
void sh_emit(sh_host *h, const char *event, const char *fmt, ...);

/* Engine-side binding helpers -------------------------------------------- */

/* Add C functions to the shared `engine` table visible from every script. */
void  sh_register(sh_host *h, const luaL_Reg *fns);
/* Retrieve sh_config.engine from inside a binding. */
void *sh_engine_ctx(lua_State *L);

const char *sh_last_error(const sh_host *h);
size_t      sh_mem_used(const sh_host *h);

#endif /* SCRIPT_HOST_H */
