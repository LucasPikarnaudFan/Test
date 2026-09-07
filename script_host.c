/* script_host.c — see script_host.h */
#define _POSIX_C_SOURCE 200809L

#include "script_host.h"

#include <lualib.h>

#include <dirent.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define SH_MAX_SCRIPTS 64
#define SH_MAX_TASKS   256
#define SH_HOOK_GRAIN  2048   /* VM instructions between watchdog checks */

typedef struct {
    char   name[64];
    char   path[512];
    time_t mtime;
    int    env_ref;      /* registry ref -> sandbox env table */
    int    used;
} sh_script;

typedef struct {
    lua_State *co;
    int        thread_ref;   /* registry ref keeps the thread from being GC'd */
    double     resume_at;
    int        sid;
    int        started;
    int        used;
} sh_task;

struct sh_host {
    lua_State *L;
    sh_config  cfg;

    size_t mem_used;
    long   budget_left;

    double now;
    double dt;
    double reload_accum;

    int safe_ref;      /* whitelisted globals shared by every sandbox */
    int engine_ref;    /* the `engine` table                          */
    int handlers_ref;  /* flat array of {ev=, fn=, sid=}              */

    sh_script scripts[SH_MAX_SCRIPTS];
    sh_task   tasks[SH_MAX_TASKS];

    char last_error[512];
};

/* ------------------------------------------------------------------ utils */

static void sh_log(sh_host *h, const char *level, const char *fmt, ...)
{
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (h->cfg.log) h->cfg.log(h->cfg.log_ud, level, buf);
    else fprintf(stderr, "[%s] %s\n", level, buf);
}

static void sh_fail(sh_host *h, const char *msg)
{
    snprintf(h->last_error, sizeof h->last_error, "%s", msg ? msg : "(nil)");
    sh_log(h, "error", "%s", h->last_error);
}

static sh_host *sh_self(lua_State *L)
{
    return *(sh_host **)lua_getextraspace(L);
}

void *sh_engine_ctx(lua_State *L) { return sh_self(L)->cfg.engine; }
const char *sh_last_error(const sh_host *h) { return h->last_error; }
size_t sh_mem_used(const sh_host *h) { return h->mem_used; }

/* --------------------------------------------------- allocator + watchdog */

static void *sh_alloc(void *ud, void *ptr, size_t osize, size_t nsize)
{
    sh_host *h = (sh_host *)ud;
    size_t live = h->mem_used - (ptr ? osize : 0);

    if (nsize == 0) {
        free(ptr);
        h->mem_used = live;
        return NULL;
    }
    if (h->cfg.mem_limit && live + nsize > h->cfg.mem_limit)
        return NULL;                     /* VM raises "not enough memory" */

    void *np = realloc(ptr, nsize);
    if (np) h->mem_used = live + nsize;
    return np;
}

static void sh_watchdog(lua_State *L, lua_Debug *ar)
{
    sh_host *h = sh_self(L);
    (void)ar;
    h->budget_left -= SH_HOOK_GRAIN;
    if (h->budget_left <= 0)
        luaL_error(L, "instruction budget exhausted (runaway script)");
}

static void sh_arm(sh_host *h, lua_State *T)
{
    if (h->cfg.step_budget > 0)
        lua_sethook(T, sh_watchdog, LUA_MASKCOUNT, SH_HOOK_GRAIN);
    else
        lua_sethook(T, NULL, 0, 0);
}

static int sh_msgh(lua_State *L)
{
    const char *msg = lua_tostring(L, 1);
    if (!msg) msg = "(non-string error)";
    luaL_traceback(L, L, msg, 1);
    return 1;
}

/* Protected call that resets the instruction budget first. */
static int sh_pcall(sh_host *h, int nargs, int nres)
{
    lua_State *L = h->L;
    int base = lua_gettop(L) - nargs;      /* function slot */
    lua_pushcfunction(L, sh_msgh);
    lua_insert(L, base);
    h->budget_left = h->cfg.step_budget;
    int st = lua_pcall(L, nargs, nres, base);
    lua_remove(L, base);
    if (st != LUA_OK) {
        sh_fail(h, lua_tostring(L, -1));
        lua_pop(L, 1);
    }
    return st;
}

/* ------------------------------------------------------- engine.* bindings */

static int api_log(lua_State *L)
{
    sh_host *h = sh_self(L);
    luaL_Buffer b;
    int n = lua_gettop(L);
    luaL_buffinit(L, &b);
    for (int i = 1; i <= n; i++) {
        if (i > 1) luaL_addchar(&b, ' ');
        luaL_tolstring(L, i, NULL);       /* honours __tostring */
        luaL_addvalue(&b);
    }
    luaL_pushresult(&b);
    lua_getfield(L, LUA_REGISTRYINDEX, "sh.script");
    sh_log(h, "lua", "%s: %s", lua_tostring(L, -1) ? lua_tostring(L, -1) : "?",
           lua_tostring(L, -2));
    return 0;
}

static int api_time(lua_State *L)
{
    lua_pushnumber(L, sh_self(L)->now);
    return 1;
}

static int api_dt(lua_State *L)
{
    lua_pushnumber(L, sh_self(L)->dt);
    return 1;
}

/* engine.on(event, fn) — register a handler owned by the calling script. */
static int api_on(lua_State *L)
{
    sh_host *h = sh_self(L);
    const char *ev = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TFUNCTION);

    lua_rawgeti(L, LUA_REGISTRYINDEX, h->handlers_ref);
    lua_newtable(L);
    lua_pushstring(L, ev);   lua_setfield(L, -2, "ev");
    lua_pushvalue(L, 2);     lua_setfield(L, -2, "fn");
    lua_getfield(L, LUA_REGISTRYINDEX, "sh.sid");
    lua_setfield(L, -2, "sid");
    lua_rawseti(L, -2, (lua_Integer)lua_rawlen(L, -2) + 1);
    lua_pop(L, 1);
    return 0;
}

static sh_task *sh_task_slot(sh_host *h)
{
    for (int i = 0; i < SH_MAX_TASKS; i++)
        if (!h->tasks[i].used) return &h->tasks[i];
    return NULL;
}

/* engine.spawn_task(fn, ...) — coroutine that may call engine.wait(). */
static int api_spawn_task(lua_State *L)
{
    sh_host *h = sh_self(L);
    int extra = lua_gettop(L) - 1;
    luaL_checktype(L, 1, LUA_TFUNCTION);

    sh_task *t = sh_task_slot(h);
    if (!t) return luaL_error(L, "task table full (%d)", SH_MAX_TASKS);

    lua_State *co = lua_newthread(L);
    t->thread_ref = luaL_ref(L, LUA_REGISTRYINDEX);   /* pops the thread */
    lua_pushvalue(L, 1);
    for (int i = 0; i < extra; i++) lua_pushvalue(L, 2 + i);
    lua_xmove(L, co, 1 + extra);
    sh_arm(h, co);

    lua_getfield(L, LUA_REGISTRYINDEX, "sh.sid");
    t->sid       = (int)lua_tointeger(L, -1);
    lua_pop(L, 1);
    t->co        = co;
    t->resume_at = h->now;
    t->started   = 0;
    t->used      = 1;

    lua_pushinteger(L, (lua_Integer)(t - h->tasks));
    return 1;
}

/* engine.wait(seconds) — yields the running task, returns elapsed seconds. */
static int api_wait(lua_State *L)
{
    double sec = luaL_optnumber(L, 1, 0.0);
    if (lua_pushthread(L)) return luaL_error(L, "engine.wait: not in a task");
    lua_pop(L, 1);
    if (sec < 0) sec = 0;
    lua_pushnumber(L, sec);
    return lua_yield(L, 1);
}

static const luaL_Reg sh_core_api[] = {
    {"log",        api_log},
    {"time",       api_time},
    {"dt",         api_dt},
    {"on",         api_on},
    {"spawn_task", api_spawn_task},
    {"wait",       api_wait},
    {NULL, NULL}
};

void sh_register(sh_host *h, const luaL_Reg *fns)
{
    lua_State *L = h->L;
    lua_rawgeti(L, LUA_REGISTRYINDEX, h->engine_ref);
    luaL_setfuncs(L, fns, 0);
    lua_pop(L, 1);
}

/* ------------------------------------------------------------- sandboxing */

/* Copy one whitelisted global from _G into the safe table on top of stack. */
static void sh_keep(lua_State *L, const char *name)
{
    lua_getglobal(L, name);
    lua_setfield(L, -2, name);
}

static void sh_build_sandbox(sh_host *h)
{
    lua_State *L = h->L;
    static const luaL_Reg libs[] = {
        {LUA_GNAME,     luaopen_base},
        {LUA_TABLIBNAME, luaopen_table},
        {LUA_STRLIBNAME, luaopen_string},
        {LUA_MATHLIBNAME, luaopen_math},
        {LUA_COLIBNAME,  luaopen_coroutine},
        {LUA_UTF8LIBNAME, luaopen_utf8},
        {NULL, NULL}
    };
    /* io, os, debug and package are never opened: nothing to leak. */
    for (const luaL_Reg *l = libs; l->func; l++) {
        luaL_requiref(L, l->name, l->func, 1);
        lua_pop(L, 1);
    }

    lua_newtable(L);                                   /* safe globals */
    static const char *keep[] = {
        "assert", "error", "ipairs", "next", "pairs", "pcall", "select",
        "tonumber", "tostring", "type", "xpcall", "rawequal", "rawget",
        "rawlen", "rawset", "setmetatable", "getmetatable",
        "string", "table", "math", "coroutine", "utf8", NULL
    };
    for (const char **k = keep; *k; k++) sh_keep(L, *k);
    /* deliberately absent: load, loadstring, dofile, loadfile, require,
     * collectgarbage, print, _G, io, os, debug, package. */
    lua_pushliteral(L, "Lua 5.4 (sandboxed)");
    lua_setfield(L, -2, "_VERSION");
    h->safe_ref = luaL_ref(L, LUA_REGISTRYINDEX);

    lua_newtable(L);                                   /* engine table */
    luaL_setfuncs(L, sh_core_api, 0);
    h->engine_ref = luaL_ref(L, LUA_REGISTRYINDEX);

    lua_newtable(L);                                   /* handlers */
    h->handlers_ref = luaL_ref(L, LUA_REGISTRYINDEX);
}

/* -------------------------------------------------------- lifecycle: host */

sh_host *sh_create(const sh_config *cfg)
{
    sh_host *h = (sh_host *)calloc(1, sizeof *h);
    if (!h) return NULL;
    h->cfg = *cfg;

    h->L = lua_newstate(sh_alloc, h);
    if (!h->L) { free(h); return NULL; }
    *(sh_host **)lua_getextraspace(h->L) = h;

    lua_atpanic(h->L, NULL);
    sh_build_sandbox(h);
    sh_arm(h, h->L);
    return h;
}

void sh_destroy(sh_host *h)
{
    if (!h) return;
    lua_close(h->L);        /* frees every ref, thread and env in one shot */
    free(h);
}

/* ------------------------------------------------------ lifecycle: script */

static sh_script *sh_find(sh_host *h, const char *name)
{
    for (int i = 0; i < SH_MAX_SCRIPTS; i++)
        if (h->scripts[i].used && !strcmp(h->scripts[i].name, name))
            return &h->scripts[i];
    return NULL;
}

/* Drop every handler and task owned by script id `sid`. */
static void sh_purge(sh_host *h, int sid)
{
    lua_State *L = h->L;
    lua_rawgeti(L, LUA_REGISTRYINDEX, h->handlers_ref);
    int n = (int)lua_rawlen(L, -1), keep = 0;
    for (int i = 1; i <= n; i++) {
        lua_rawgeti(L, -1, i);
        lua_getfield(L, -1, "sid");
        int owner = (int)lua_tointeger(L, -1);
        lua_pop(L, 1);
        if (owner == sid) { lua_pop(L, 1); continue; }
        lua_rawseti(L, -2, ++keep);
    }
    for (int i = keep + 1; i <= n; i++) {
        lua_pushnil(L);
        lua_rawseti(L, -2, i);
    }
    lua_pop(L, 1);

    for (int i = 0; i < SH_MAX_TASKS; i++) {
        sh_task *t = &h->tasks[i];
        if (t->used && t->sid == sid) {
            luaL_unref(L, LUA_REGISTRYINDEX, t->thread_ref);
            memset(t, 0, sizeof *t);
        }
    }
}

static void sh_basename(const char *path, char *out, size_t cap)
{
    const char *slash = strrchr(path, '/');
    const char *base  = slash ? slash + 1 : path;
    snprintf(out, cap, "%s", base);
    char *dot = strrchr(out, '.');
    if (dot && dot != out) *dot = '\0';
}

static char *sh_slurp(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    if (n < 0) { fclose(f); return NULL; }
    rewind(f);
    char *buf = (char *)malloc((size_t)n + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t got = fread(buf, 1, (size_t)n, f);
    fclose(f);
    buf[got] = '\0';
    *len = got;
    return buf;
}

int sh_load_file(sh_host *h, const char *path)
{
    lua_State *L = h->L;
    char name[64];
    sh_basename(path, name, sizeof name);

    sh_script *s = sh_find(h, name);
    int reload = s != NULL;
    if (!s) {
        for (int i = 0; i < SH_MAX_SCRIPTS; i++)
            if (!h->scripts[i].used) { s = &h->scripts[i]; break; }
        if (!s) { sh_fail(h, "script table full"); return -1; }
    }
    int sid = (int)(s - h->scripts);

    size_t len = 0;
    char *src = sh_slurp(path, &len);
    if (!src) { sh_fail(h, "cannot read script file"); return -1; }

    char chunkname[520];
    snprintf(chunkname, sizeof chunkname, "@%s", path);
    /* mode "t": text only. Precompiled bytecode is not a safe input. */
    int st = luaL_loadbufferx(L, src, len, chunkname, "t");
    free(src);
    if (st != LUA_OK) {
        sh_fail(h, lua_tostring(L, -1));
        lua_pop(L, 1);
        return -1;
    }

    if (reload) sh_purge(h, sid);

    /* Fresh env; `state` survives a reload so live scripts keep their data. */
    lua_newtable(L);
    if (reload) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, s->env_ref);
        lua_getfield(L, -1, "state");
        lua_remove(L, -2);
        if (lua_isnil(L, -1)) { lua_pop(L, 1); lua_newtable(L); }
    } else {
        lua_newtable(L);
    }
    lua_setfield(L, -2, "state");

    lua_rawgeti(L, LUA_REGISTRYINDEX, h->engine_ref);
    lua_setfield(L, -2, "engine");
    lua_pushstring(L, name);
    lua_setfield(L, -2, "SCRIPT");

    lua_newtable(L);                                   /* metatable */
    lua_rawgeti(L, LUA_REGISTRYINDEX, h->safe_ref);
    lua_setfield(L, -2, "__index");
    lua_pushliteral(L, "sandbox");
    lua_setfield(L, -2, "__metatable");                /* not introspectable */
    lua_setmetatable(L, -2);

    lua_pushvalue(L, -1);
    if (reload) luaL_unref(L, LUA_REGISTRYINDEX, s->env_ref);
    s->env_ref = luaL_ref(L, LUA_REGISTRYINDEX);

    if (!lua_setupvalue(L, -2, 1)) {                   /* chunk _ENV */
        lua_pop(L, 1);
        sh_fail(h, "chunk has no _ENV upvalue");
        return -1;
    }

    s->used  = 1;
    snprintf(s->name, sizeof s->name, "%s", name);
    snprintf(s->path, sizeof s->path, "%s", path);
    struct stat st_buf;
    s->mtime = (stat(path, &st_buf) == 0) ? st_buf.st_mtime : 0;

    /* sh.sid / sh.script tell the bindings who is currently running. */
    lua_pushinteger(L, sid);
    lua_setfield(L, LUA_REGISTRYINDEX, "sh.sid");
    lua_pushstring(L, name);
    lua_setfield(L, LUA_REGISTRYINDEX, "sh.script");

    if (sh_pcall(h, 0, 0) != LUA_OK) {
        sh_purge(h, sid);
        return -1;
    }
    sh_log(h, "info", "%s %s", reload ? "reloaded" : "loaded", path);
    return sid;
}

int sh_load_dir(sh_host *h, const char *dir)
{
    DIR *d = opendir(dir);
    if (!d) { sh_fail(h, "cannot open script directory"); return -1; }
    struct dirent *e;
    int n = 0;
    while ((e = readdir(d))) {
        const char *dot = strrchr(e->d_name, '.');
        if (!dot || strcmp(dot, ".lua")) continue;
        char path[512];
        snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
        if (sh_load_file(h, path) >= 0) n++;
    }
    closedir(d);
    return n;
}

void sh_unload(sh_host *h, const char *name)
{
    sh_script *s = sh_find(h, name);
    if (!s) return;
    sh_purge(h, (int)(s - h->scripts));
    luaL_unref(h->L, LUA_REGISTRYINDEX, s->env_ref);
    memset(s, 0, sizeof *s);
    sh_log(h, "info", "unloaded %s", name);
}

/* ---------------------------------------------------------- dispatch loop */

static void sh_set_current(sh_host *h, int sid)
{
    lua_State *L = h->L;
    lua_pushinteger(L, sid);
    lua_setfield(L, LUA_REGISTRYINDEX, "sh.sid");
    lua_pushstring(L, (sid >= 0 && h->scripts[sid].used)
                       ? h->scripts[sid].name : "?");
    lua_setfield(L, LUA_REGISTRYINDEX, "sh.script");
}

/* Push the args described by fmt; returns how many were pushed. */
static int sh_push_args(lua_State *L, const char *fmt, va_list ap)
{
    int n = 0;
    for (const char *c = fmt; c && *c; c++, n++) {
        switch (*c) {
        case 'n': lua_pushnumber (L, va_arg(ap, double));            break;
        case 'i': lua_pushinteger(L, (lua_Integer)va_arg(ap, int));  break;
        case 's': lua_pushstring (L, va_arg(ap, const char *));      break;
        case 'b': lua_pushboolean(L, va_arg(ap, int));               break;
        default:  lua_pushnil(L);                                    break;
        }
    }
    return n;
}

static void sh_dispatch(sh_host *h, const char *event, const char *fmt,
                        va_list ap)
{
    lua_State *L = h->L;
    lua_rawgeti(L, LUA_REGISTRYINDEX, h->handlers_ref);
    int n = (int)lua_rawlen(L, -1);

    for (int i = 1; i <= n; i++) {
        lua_rawgeti(L, -1, i);
        if (!lua_istable(L, -1)) { lua_pop(L, 1); continue; }

        lua_getfield(L, -1, "ev");
        int match = lua_tostring(L, -1) && !strcmp(lua_tostring(L, -1), event);
        lua_pop(L, 1);
        if (!match) { lua_pop(L, 1); continue; }

        lua_getfield(L, -1, "sid");
        sh_set_current(h, (int)lua_tointeger(L, -1));
        lua_pop(L, 1);

        lua_getfield(L, -1, "fn");
        lua_remove(L, -2);                 /* drop the entry table */
        va_list copy;
        va_copy(copy, ap);
        int nargs = sh_push_args(L, fmt, copy);
        va_end(copy);
        sh_pcall(h, nargs, 0);
    }
    lua_pop(L, 1);
}

void sh_emit(sh_host *h, const char *event, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    sh_dispatch(h, event, fmt, ap);
    va_end(ap);
}

static void sh_run_tasks(sh_host *h)
{
    for (int i = 0; i < SH_MAX_TASKS; i++) {
        sh_task *t = &h->tasks[i];
        if (!t->used || h->now < t->resume_at) continue;

        sh_set_current(h, t->sid);
        h->budget_left = h->cfg.step_budget;

        int nargs = 0;
        if (t->started) {                    /* hand back the slept time */
            lua_pushnumber(t->co, h->now - t->resume_at + h->dt);
            nargs = 1;
        }
        t->started = 1;

        int nres = 0;
        int st = lua_resume(t->co, h->L, nargs, &nres);

        if (st == LUA_YIELD) {
            double sec = (nres >= 1) ? lua_tonumber(t->co, -nres) : 0.0;
            lua_pop(t->co, nres);
            t->resume_at = h->now + sec;
        } else {
            if (st != LUA_OK) {
                const char *msg = lua_tostring(t->co, -1);
                luaL_traceback(h->L, t->co, msg ? msg : "task error", 0);
                sh_fail(h, lua_tostring(h->L, -1));
                lua_pop(h->L, 1);
            }
            luaL_unref(h->L, LUA_REGISTRYINDEX, t->thread_ref);
            memset(t, 0, sizeof *t);
        }
    }
}

static void sh_scan_reload(sh_host *h)
{
    for (int i = 0; i < SH_MAX_SCRIPTS; i++) {
        sh_script *s = &h->scripts[i];
        if (!s->used) continue;
        struct stat st;
        if (stat(s->path, &st) != 0) continue;
        if (st.st_mtime != s->mtime) {
            char path[512];
            snprintf(path, sizeof path, "%s", s->path);
            sh_load_file(h, path);
        }
    }
}

void sh_tick(sh_host *h, double dt)
{
    h->dt   = dt;
    h->now += dt;

    if (h->cfg.reload_period > 0) {
        h->reload_accum += dt;
        if (h->reload_accum >= h->cfg.reload_period) {
            h->reload_accum = 0;
            sh_scan_reload(h);
        }
    }
    sh_emit(h, "update", "n", dt);
    sh_run_tasks(h);
}
