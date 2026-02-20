import { sshExec } from "../lib/ssh.js";
import { getDefaultAlias } from "../lib/config.js";

export const serverStatusTool = {
  name: "server_status",
  description:
    "Check current state of a VPS server: running containers (names, ports, status), free RAM and disk space, occupied ports, and installed stacks.",
  inputSchema: {
    type: "object" as const,
    properties: {
      ssh_alias: {
        type: "string",
        description:
          "SSH alias. If omitted, uses the default configured server.",
      },
    },
  },
};

export async function handleServerStatus(
  args: Record<string, unknown>
): Promise<{ content: Array<{ type: string; text: string }>; isError?: boolean }> {
  const alias = (args.ssh_alias as string) ?? getDefaultAlias();

  if (!/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/.test(alias)) {
    return {
      isError: true,
      content: [
        { type: "text", text: `Invalid SSH alias '${alias}'. Use only letters, numbers, dashes, underscores.` },
      ],
    };
  }

  const cmd = [
    'echo "===RESOURCES==="',
    'echo "RAM_TOTAL=$(free -m 2>/dev/null | awk \'/^Mem:/ {print $2}\')"',
    'echo "RAM_AVAILABLE=$(free -m 2>/dev/null | awk \'/^Mem:/ {print $7}\')"',
    'echo "DISK_TOTAL=$(df -m / 2>/dev/null | awk \'NR==2 {print $2}\')"',
    'echo "DISK_AVAILABLE=$(df -m / 2>/dev/null | awk \'NR==2 {print $4}\')"',
    'echo "DOCKER_OK=$(docker --version 2>/dev/null && echo YES || echo NO)"',
    'echo "===CONTAINERS==="',
    "docker ps -a --format '{{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.Ports}}' 2>/dev/null || echo 'NO_DOCKER'",
    'echo "===PORTS==="',
    "ss -tlnp 2>/dev/null | awk 'NR>1 {print $4}' | grep -oE '[0-9]+$' | sort -un",
    'echo "===STACKS==="',
    "ls -1 /opt/stacks/ 2>/dev/null || echo 'NONE'",
  ].join("; ");

  const res = await sshExec(alias, cmd);
  if (res.exitCode !== 0 && !res.stdout.includes("===RESOURCES===")) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text: [
            `Failed to connect to server '${alias}'`,
            "",
            res.stderr.trim() || "Connection failed",
            "",
            "Run configure_server first to set up the connection.",
          ].join("\n"),
        },
      ],
    };
  }

  const output = res.stdout;

  // Parse resources
  const ramTotal = output.match(/RAM_TOTAL=(\d+)/)?.[1] ?? "?";
  const ramAvail = output.match(/RAM_AVAILABLE=(\d+)/)?.[1] ?? "?";
  const diskTotal = output.match(/DISK_TOTAL=(\d+)/)?.[1] ?? "?";
  const diskAvail = output.match(/DISK_AVAILABLE=(\d+)/)?.[1] ?? "?";
  const hasDocker = output.includes("DOCKER_OK=Docker version");

  // Parse containers
  const containerSection =
    output.split("===CONTAINERS===")[1]?.split("===PORTS===")[0] ?? "";
  const containerLines = containerSection
    .trim()
    .split("\n")
    .filter((l) => l && l !== "NO_DOCKER");

  // Parse ports
  const portsSection =
    output.split("===PORTS===")[1]?.split("===STACKS===")[0] ?? "";
  const ports = portsSection
    .trim()
    .split("\n")
    .filter((l) => l.match(/^\d+$/));

  // Parse stacks
  const stacksSection = output.split("===STACKS===")[1] ?? "";
  const stacks = stacksSection
    .trim()
    .split("\n")
    .filter((l) => l && l !== "NONE");

  const lines: string[] = [
    `Server Status: ${alias}`,
    "",
    "Resources:",
    `  RAM:  ${ramAvail}MB available / ${ramTotal}MB total`,
    `  Disk: ${diskAvail}MB available / ${diskTotal}MB total`,
  ];

  if (containerLines.length > 0) {
    lines.push("", `Running Containers (${containerLines.length}):`);
    for (const c of containerLines) {
      const [name, image, status, cports] = c.split("\t");
      lines.push(`  ${name ?? "?"} | ${image ?? "?"} | ${status ?? "?"} | ${cports ?? ""}`);
    }
  } else {
    lines.push("", "No running containers.");
  }

  if (ports.length > 0) {
    lines.push("", `Occupied Ports: ${ports.join(", ")}`);
  }

  if (stacks.length > 0) {
    lines.push("", `Installed Stacks: ${stacks.join(", ")}`);
  }

  if (!hasDocker) {
    lines.push("");
    lines.push("WARNING: Docker is NOT installed on this server.");
    lines.push("Most toolbox apps require Docker. Suggest the user run the");
    lines.push("built-in 'start' script: ssh <alias> → start → answer T to Docker question.");
    lines.push("Or install manually: curl -fsSL https://get.docker.com | sh");
  }

  // Health verdict based on resource utilization
  const ramTotalNum = parseInt(ramTotal, 10);
  const ramAvailNum = parseInt(ramAvail, 10);
  const diskTotalNum = parseInt(diskTotal, 10);
  const diskAvailNum = parseInt(diskAvail, 10);

  if (ramTotalNum && diskTotalNum) {
    const ramUsedPct = Math.round(((ramTotalNum - ramAvailNum) / ramTotalNum) * 100);
    const diskUsedPct = Math.round(((diskTotalNum - diskAvailNum) / diskTotalNum) * 100);

    const ramCritical = ramUsedPct > 80;
    const ramWarn = ramUsedPct > 60;
    const diskCritical = diskUsedPct > 85;
    const diskWarn = diskUsedPct > 60;

    lines.push("");
    if (ramCritical || diskCritical) {
      lines.push("Health: CRITICAL — Server under heavy load! Consider upgrading or removing unused services.");
    } else if (ramWarn || diskWarn) {
      lines.push("Health: WARNING — Resources getting tight. Consider upgrading before adding heavy services.");
    } else {
      lines.push("Health: OK — Server in good shape. You can safely add more services.");
    }

    // Upgrade suggestion for warning/critical
    if (ramWarn || diskWarn) {
      if (ramTotalNum <= 1024) {
        lines.push("Suggestion: consider a VPS with more RAM (at least 2GB recommended)");
      } else if (ramTotalNum <= 2048) {
        lines.push("Suggestion: consider a VPS with more RAM (at least 4GB recommended)");
      } else if (ramTotalNum <= 4096) {
        lines.push("Suggestion: consider a VPS with more RAM (at least 8GB recommended)");
      }
    }
  }

  return { content: [{ type: "text", text: lines.join("\n") }] };
}
