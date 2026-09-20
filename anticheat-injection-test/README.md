# Anti-cheat injection test harness

Test case for validating that an anti-cheat detects live JVM agent
injection into a running Minecraft client (Recube), using the same
mechanism real cheat-loaders use: the JDK Attach API
(`com.sun.tools.attach`) + `java.lang.instrument`, not native DLL injection
(Minecraft clients are JVM processes, so DLL injection doesn't apply here).

**Only run this against your own Recube/Minecraft process, on your own
machine.**

## What's here

- `src/TestPayloadAgent.java` — the injected payload. Does nothing
  malicious: on load it logs a line (PID, timestamp) and writes a marker
  file to the OS temp dir. No memory reads, no hooks into game code, no
  automation. It exists purely to be a detectable "something attached"
  event.
- `src/Injector.java` — attaches to a running JVM by PID or by a
  case-insensitive substring of its display name (e.g. `recube`), then
  calls `VirtualMachine.loadAgent(...)` to load the payload — this is the
  actual attack primitive you're testing detection against.
- `src/agent-manifest.mf` — JAR manifest declaring the agent entry points.
- `build.bat` — compiles everything and packages `agent.jar`.

## Build

```
build.bat
```

## Run

1. Start Recube/Minecraft normally.
2. List running JVMs to find it:
   ```
   java --add-modules jdk.attach -cp out Injector --list
   ```
3. Inject the test payload (by PID or name substring):
   ```
   java --add-modules jdk.attach -cp out Injector <pid-or-name> out\agent.jar
   ```
4. Check:
   - The target process's stdout/log for the `[TestPayloadAgent]` line.
   - `%TEMP%\anticheat_test_marker.txt` for the appended marker.
   - **Whether your anti-cheat flagged the attach at all.** If it didn't,
     that's your finding — see detection hooks below.

## What your anti-cheat should be watching for

Live agent attach leaves several observable traces, in rough order of
reliability:

1. **`Instrumentation` presence / unexpected class transformers.** A
   process that never loaded `-javaagent` at startup suddenly having an
   active `Instrumentation` instance (or a `ClassFileTransformer`
   registered) is anomalous. If your anti-cheat runs inside the same JVM,
   it can self-check via reflection on the running agent list, or by
   registering its own transformer first and watching for others
   appearing later.
2. **Attach-mechanism artifacts.** On the attaching side, the Attach API
   creates a Unix domain socket / named pipe and (on some JVM versions) a
   temporary `.attach_pid<PID>` file to signal the target JVM's Attach
   Listener thread. Watching for the `Attach Listener` thread transitioning
   from idle to active, or for that trigger file appearing, is a solid
   signal.
2. **New/renamed threads.** `VirtualMachine.loadAgent` causes the target
   JVM to spin up the Attach Listener thread if it wasn't already running,
   and the agent's own code often starts extra threads. Diffing the thread
   list (`ManagementFactory.getThreadMXBean()`) against a baseline taken at
   launch is cheap and effective.
3. **Loaded classes / classloaders that don't trace back to the game's own
   jar or expected mod loader.** Enumerate loaded classes periodically
   (via your own `Instrumentation.getAllLoadedClasses()` if you get in
   first) and flag classes whose defining classloader isn't one you
   recognize.
4. **JAR/manifest fingerprints.** If you can capture the injected jar
   (e.g. from the loader's temp copy), manifest attributes like
   `Agent-Class` are themselves a signal — a class file with no legitimate
   mod/plugin association declaring itself an agent is suspicious by
   construction.
5. **Timing side-channel.** Loading an agent briefly pauses the target JVM
   (safepoint) for class retransformation. An anti-cheat with a heartbeat
   thread can notice an unexplained stall.

The realistic bar for (1) and (2) is: get your own agent/monitor loaded
*before* the game starts accepting untrusted input (via `-javaagent` at
launch, from your launcher), so you have a first-mover advantage — a
detector that only starts after the fact can be attached-to itself.
