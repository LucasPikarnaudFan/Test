/* demo_engine.c — a stand-in "game engine": entity table, fixed-step loop,
 * and the C bindings that the Lua runtime injects into every sandbox. */
#define _POSIX_C_SOURCE 200809L

#include "script_host.h"

#include <math.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define WORLD_MAX 256

typedef struct {
    int    id;
    char   kind[24];
    double x, y;
    double hp;
    int    alive;
} entity;

typedef struct {
    entity ents[WORLD_MAX];
    int    next_id;
    int    deaths[WORLD_MAX];
    int    death_count;
} world;

static entity *world_find(world *w, int id)
{
    for (int i = 0; i < WORLD_MAX; i++)
        if (w->ents[i].alive && w->ents[i].id == id) return &w->ents[i];
    return NULL;
}

/* ------------------------------------------------------- engine bindings */

#define WORLD(L) ((world *)sh_engine_ctx(L))

static int e_spawn(lua_State *L)
{
    world *w = WORLD(L);
    const char *kind = luaL_checkstring(L, 1);
    double x = luaL_optnumber(L, 2, 0), y = luaL_optnumber(L, 3, 0);

    for (int i = 0; i < WORLD_MAX; i++) {
        entity *e = &w->ents[i];
        if (e->alive) continue;
        e->id = ++w->next_id;
        snprintf(e->kind, sizeof e->kind, "%s", kind);
        e->x = x; e->y = y; e->hp = 100.0; e->alive = 1;
        lua_pushinteger(L, e->id);
        return 1;
    }
    return luaL_error(L, "world is full");
}

static int e_destroy(lua_State *L)
{
    entity *e = world_find(WORLD(L), (int)luaL_checkinteger(L, 1));
    if (e) e->alive = 0;
    lua_pushboolean(L, e != NULL);
    return 1;
}

static int e_pos(lua_State *L)
{
    entity *e = world_find(WORLD(L), (int)luaL_checkinteger(L, 1));
    if (!e) return 0;
    lua_pushnumber(L, e->x);
    lua_pushnumber(L, e->y);
    return 2;
}

static int e_set_pos(lua_State *L)
{
    entity *e = world_find(WORLD(L), (int)luaL_checkinteger(L, 1));
    if (!e) return luaL_error(L, "set_pos: dead or unknown entity");
    e->x = luaL_checknumber(L, 2);
    e->y = luaL_checknumber(L, 3);
    return 0;
}

static int e_hp(lua_State *L)
{
    entity *e = world_find(WORLD(L), (int)luaL_checkinteger(L, 1));
    if (!e) return 0;
    lua_pushnumber(L, e->hp);
    return 1;
}

static int e_hurt(lua_State *L)
{
    world *w = WORLD(L);
    entity *e = world_find(w, (int)luaL_checkinteger(L, 1));
    if (!e) return 0;
    e->hp -= luaL_checknumber(L, 2);
    if (e->hp <= 0 && w->death_count < WORLD_MAX) {
        e->alive = 0;                       /* queued: the loop emits "death",
                                             * so we never re-enter Lua here */
        w->deaths[w->death_count++] = e->id;
    }
    lua_pushnumber(L, e->hp);
    return 1;
}

static int e_each(lua_State *L)
{
    world *w = WORLD(L);
    const char *kind = luaL_optstring(L, 1, NULL);
    lua_newtable(L);
    int n = 0;
    for (int i = 0; i < WORLD_MAX; i++) {
        entity *e = &w->ents[i];
        if (!e->alive) continue;
        if (kind && strcmp(e->kind, kind)) continue;
        lua_pushinteger(L, e->id);
        lua_rawseti(L, -2, ++n);
    }
    return 1;
}

static const luaL_Reg engine_bindings[] = {
    {"spawn",   e_spawn},
    {"destroy", e_destroy},
    {"pos",     e_pos},
    {"set_pos", e_set_pos},
    {"hp",      e_hp},
    {"hurt",    e_hurt},
    {"each",    e_each},
    {NULL, NULL}
};

/* ---------------------------------------------------------------- driver */

static void host_log(void *ud, const char *level, const char *msg)
{
    (void)ud;
    printf("  %-5s | %s\n", level, msg);
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0);   /* keep the log readable live */
    const char *dir = "scripts";
    int realtime = 0, ticks = 240;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--realtime")) { realtime = 1; ticks = 3600; }
        else dir = argv[i];
    }
    static world w;

    sh_config cfg = {
        .engine        = &w,
        .mem_limit     = 8u * 1024 * 1024,
        .step_budget   = 2000000,
        .reload_period = 0.5,
        .log           = host_log,
        .log_ud        = NULL,
    };

    sh_host *h = sh_create(&cfg);
    if (!h) { fprintf(stderr, "sh_create failed\n"); return 1; }
    sh_register(h, engine_bindings);

    printf("== loading %s ==\n", dir);
    sh_load_dir(h, dir);

    printf("== running %d ticks @ 60 Hz%s ==\n", ticks,
           realtime ? " (real time; edit scripts/ to hot reload)" : "");
    const double dt = 1.0 / 60.0;
    for (int tick = 1; tick <= ticks; tick++) {
        sh_tick(h, dt);
        if (realtime) {
            struct timespec ts = { 0, (long)(dt * 1e9) };
            nanosleep(&ts, NULL);
        }

        if (tick == 60) sh_emit(h, "damage", "ii", 1, 30);
        if (tick == 120) sh_emit(h, "damage", "ii", 1, 80);

        for (int i = 0; i < w.death_count; i++)
            sh_emit(h, "death", "i", w.deaths[i]);
        w.death_count = 0;

        if (tick % 60 == 0) {
            printf("  tick %3d  entities:", tick);
            for (int i = 0; i < WORLD_MAX; i++)
                if (w.ents[i].alive)
                    printf(" %s#%d(%.1f,%.1f)", w.ents[i].kind, w.ents[i].id,
                           w.ents[i].x, w.ents[i].y);
            printf("\n           vm heap: %zu bytes\n", sh_mem_used(h));
        }
    }

    if (realtime) { sh_destroy(h); return 0; }

    printf("== watchdog check ==\n");
    if (sh_load_file(h, "demos/runaway.lua") < 0)
        printf("  killed as expected: %s\n", sh_last_error(h));
    else
        printf("  WARNING: runaway script was not stopped\n");

    printf("== hot reload ==\n");
    printf("  edit a file in %s/ while this runs to see it reload\n", dir);

    sh_destroy(h);
    return 0;
}
