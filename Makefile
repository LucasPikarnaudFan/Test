# liblua is the only dependency: it is the language itself.
# Debian/Ubuntu: apt install liblua5.4-dev   macOS: brew install lua
LUA_CFLAGS ?= $(shell pkg-config --cflags lua5.4 2>/dev/null || echo -I/usr/include/lua5.4)
LUA_LIBS   ?= $(shell pkg-config --libs   lua5.4 2>/dev/null || echo -llua5.4)

CFLAGS  ?= -std=c11 -O2 -Wall -Wextra -Wpedantic
LDLIBS  := $(LUA_LIBS) -lm

all: demo_engine

demo_engine: script_host.o demo_engine.o
	$(CC) $^ -o $@ $(LDLIBS)

%.o: %.c script_host.h
	$(CC) $(CFLAGS) $(LUA_CFLAGS) -c $< -o $@

run: demo_engine
	./demo_engine scripts

clean:
	rm -f *.o demo_engine

.PHONY: all run clean
