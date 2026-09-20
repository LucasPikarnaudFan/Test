import com.sun.tools.attach.VirtualMachine;
import com.sun.tools.attach.VirtualMachineDescriptor;

import java.util.List;

/**
 * Test injector: attaches to an already-running JVM by PID (or by matching
 * a substring of its display name, e.g. "recube" or the launcher's main
 * class) and loads TestPayloadAgent into it via the standard JDK Attach API.
 *
 * This is the exact mechanism real cheat-client "injectors" use against
 * Minecraft (Attach API + java.lang.instrument), which is why it's a
 * representative test case for your anti-cheat. Run it against your own
 * running Recube/Minecraft process only.
 *
 * Usage:
 *   java --add-modules jdk.attach -cp . Injector <pid-or-name-substring> <path-to-agent.jar>
 *
 * List candidate JVMs first with:
 *   java --add-modules jdk.attach -cp . Injector --list
 */
public class Injector {

    public static void main(String[] args) throws Exception {
        if (args.length == 1 && args[0].equals("--list")) {
            listVMs();
            return;
        }
        if (args.length != 2) {
            System.err.println("Usage: Injector <pid-or-name-substring> <path-to-agent.jar>");
            System.err.println("       Injector --list");
            System.exit(1);
        }

        String target = args[0];
        String agentJarPath = args[1];

        VirtualMachineDescriptor descriptor = resolveTarget(target);
        if (descriptor == null) {
            System.err.println("No running JVM matched: " + target);
            listVMs();
            System.exit(1);
            return;
        }

        System.out.println("Attaching to pid=" + descriptor.id() + " (" + descriptor.displayName() + ")");
        VirtualMachine vm = VirtualMachine.attach(descriptor);
        try {
            vm.loadAgent(agentJarPath);
            System.out.println("Agent loaded. Check target process stdout/log and "
                    + System.getProperty("java.io.tmpdir") + "/anticheat_test_marker.txt");
        } finally {
            vm.detach();
        }
    }

    private static VirtualMachineDescriptor resolveTarget(String target) {
        List<VirtualMachineDescriptor> vms = VirtualMachine.list();
        // Exact PID match first.
        for (VirtualMachineDescriptor d : vms) {
            if (d.id().equals(target)) {
                return d;
            }
        }
        // Fall back to case-insensitive substring match on display name.
        for (VirtualMachineDescriptor d : vms) {
            if (d.displayName().toLowerCase().contains(target.toLowerCase())) {
                return d;
            }
        }
        return null;
    }

    private static void listVMs() {
        System.out.println("Running JVMs:");
        for (VirtualMachineDescriptor d : VirtualMachine.list()) {
            System.out.println("  pid=" + d.id() + "  name=" + d.displayName());
        }
    }
}
