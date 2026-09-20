import java.lang.instrument.Instrumentation;
import java.lang.management.ManagementFactory;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Instant;

/**
 * Benign test payload for validating anti-cheat detection of live JVM
 * agent injection (java.lang.instrument attach, not native DLL injection).
 *
 * It does nothing but announce itself: no memory reads, no hooks into
 * game classes, no automation. Detection should trigger on the act of
 * attachment itself, which is what this exists to exercise.
 */
public class TestPayloadAgent {

    // Entry point used when the agent is loaded into an ALREADY RUNNING JVM
    // via VirtualMachine.loadAgent(...) — the case you're testing.
    public static void agentmain(String args, Instrumentation inst) {
        announce("agentmain (live attach)", inst);
    }

    // Entry point used only if the agent is instead passed at JVM startup
    // via -javaagent:agent.jar. Included for completeness; your test case
    // is agentmain above.
    public static void premain(String args, Instrumentation inst) {
        announce("premain (startup attach)", inst);
    }

    private static void announce(String mode, Instrumentation inst) {
        String pid = ManagementFactory.getRuntimeMXBean().getName();
        String msg = "[TestPayloadAgent] injected via " + mode
                + " into JVM " + pid
                + " at " + Instant.now()
                + " canRetransform=" + inst.isRetransformClassesSupported();
        System.out.println(msg);

        // Drop a marker file so you can confirm the payload actually ran,
        // independent of whatever your anti-cheat itself observes.
        try {
            Path marker = Path.of(System.getProperty("java.io.tmpdir"), "anticheat_test_marker.txt");
            Files.writeString(marker, msg + System.lineSeparator(),
                    StandardOpenOption.CREATE, StandardOpenOption.APPEND);
        } catch (Exception e) {
            System.out.println("[TestPayloadAgent] marker write failed: " + e);
        }
    }
}
