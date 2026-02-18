import { sshExec } from "./ssh.js";

interface BackupStatus {
  hasDbBackup: boolean;
  hasCloudBackup: boolean;
  hasMikrusBackup: boolean;
}

/**
 * Check if any backup mechanism is configured on the server.
 * Returns a status object and an optional warning message for the deploy output.
 */
export async function checkBackupStatus(alias: string): Promise<string | null> {
  const result = await sshExec(
    alias,
    "echo DB:$(test -f /etc/cron.d/mikrus-db-backup && echo yes || echo no) " +
      "CLOUD:$(crontab -l 2>/dev/null | grep -q backup-core && echo yes || echo no) " +
      "MIKRUS:$(test -f /backup_key && echo yes || echo no)",
    15_000
  );

  if (result.exitCode !== 0) {
    // Can't check — don't block deployment
    return null;
  }

  const output = result.stdout.trim();
  const status: BackupStatus = {
    hasDbBackup: output.includes("DB:yes"),
    hasCloudBackup: output.includes("CLOUD:yes"),
    hasMikrusBackup: output.includes("MIKRUS:yes"),
  };

  const hasAnyBackup =
    status.hasDbBackup || status.hasCloudBackup || status.hasMikrusBackup;

  if (hasAnyBackup) {
    return null;
  }

  return (
    "\n" +
    "--- BACKUP ---\n" +
    "WARNING: No backup is configured on this server!\n" +
    "Your data (databases, files, configs) can be lost if something goes wrong.\n" +
    "\n" +
    "Use the setup_backup tool to configure backup. Available types:\n" +
    "  - setup_backup(backup_type='db')     — automatic daily database backup\n" +
    "  - setup_backup(backup_type='mikrus') — built-in Mikrus backup (200MB, free)\n" +
    "  - setup_backup(backup_type='cloud')  — cloud backup (Google Drive, Dropbox, S3)\n" +
    "\n" +
    "Ask the user if they want to configure backup now."
  );
}
