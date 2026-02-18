import { sshExec } from "./ssh.js";

interface HealthStatus {
  ramUsedPct: number;
  diskUsedPct: number;
  ramAvailMB: number;
  ramTotalMB: number;
  diskAvailMB: number;
  diskTotalMB: number;
  level: "ok" | "warning" | "critical";
}

const MIKRUS_TIERS: Array<{ maxRam: number; name: string; ram: string; price: string }> = [
  { maxRam: 1024, name: "Mikrus 3.0", ram: "2GB", price: "130 PLN/rok" },
  { maxRam: 2048, name: "Mikrus 3.5", ram: "4GB", price: "197 PLN/rok" },
  { maxRam: 4096, name: "Mikrus 4.1", ram: "8GB", price: "395 PLN/rok" },
  { maxRam: 8192, name: "Mikrus 4.2", ram: "16GB", price: "790 PLN/rok" },
];

function getUpgradeSuggestion(totalRamMB: number): string | null {
  for (const tier of MIKRUS_TIERS) {
    if (totalRamMB <= tier.maxRam) {
      return `${tier.name} (${tier.ram}, ${tier.price})`;
    }
  }
  return null; // max tier
}

function levelLabel(pct: number, isRam: boolean): string {
  if (isRam) {
    return pct > 80 ? "CRITICAL" : pct > 60 ? "WARNING" : "OK";
  }
  return pct > 85 ? "CRITICAL" : pct > 60 ? "WARNING" : "OK";
}

/**
 * Check server resource utilization after deployment.
 * Always returns a health summary string (never null).
 */
export async function checkServerHealth(alias: string): Promise<string> {
  const result = await sshExec(
    alias,
    "free -m | awk '/^Mem:/ {print $2, $7}'; df -m / | awk 'NR==2 {print $2, $4}'",
    15_000
  );

  if (result.exitCode !== 0 || !result.stdout.trim()) {
    return "\n--- SERVER HEALTH ---\nCould not check server resources.";
  }

  const lines = result.stdout.trim().split("\n");
  if (lines.length < 2) {
    return "\n--- SERVER HEALTH ---\nCould not parse server resources.";
  }

  const [ramTotal, ramAvail] = lines[0].split(/\s+/).map(Number);
  const [diskTotal, diskAvail] = lines[1].split(/\s+/).map(Number);

  if (!ramTotal || !diskTotal) {
    return "\n--- SERVER HEALTH ---\nCould not parse server resources.";
  }

  const ramUsedPct = Math.round(((ramTotal - ramAvail) / ramTotal) * 100);
  const diskUsedPct = Math.round(((diskTotal - diskAvail) / diskTotal) * 100);

  const ramLabel = levelLabel(ramUsedPct, true);
  const diskLabel = levelLabel(diskUsedPct, false);

  const worstLevel =
    ramLabel === "CRITICAL" || diskLabel === "CRITICAL"
      ? "critical"
      : ramLabel === "WARNING" || diskLabel === "WARNING"
        ? "warning"
        : "ok";

  const diskAvailGB = (diskAvail / 1024).toFixed(1);
  const diskTotalGB = (diskTotal / 1024).toFixed(1);

  const out: string[] = [
    "",
    "--- SERVER HEALTH ---",
    `RAM:  ${ramAvail}MB / ${ramTotal}MB free (${ramUsedPct}% used) — ${ramLabel}`,
    `Disk: ${diskAvailGB}GB / ${diskTotalGB}GB free (${diskUsedPct}% used) — ${diskLabel}`,
  ];

  if (worstLevel === "ok") {
    out.push("Status: Server in good shape. You can safely add more services.");
  } else if (worstLevel === "warning") {
    out.push("Status: Resources getting tight. Consider upgrading before adding heavy services.");
    const upgrade = getUpgradeSuggestion(ramTotal);
    if (upgrade) {
      out.push(`Suggested upgrade: ${upgrade}`);
      out.push("Plans: https://mikr.us/?r=pavvel#plans");
    }
  } else {
    out.push("Status: Server under heavy load! Consider upgrading or removing unused services.");
    const upgrade = getUpgradeSuggestion(ramTotal);
    if (upgrade) {
      out.push(`Suggested upgrade: ${upgrade}`);
      out.push("Plans: https://mikr.us/?r=pavvel#plans");
    }
  }

  return out.join("\n");
}
