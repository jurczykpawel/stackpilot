#!/bin/bash

# StackPilot - Unit tests for local/setup-backup.sh (restic backup wizard)
# ssh is a stub: it records arguments and the data piped to remote writes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/test-runner.sh"

setup() {
    TEST_TMPDIR=$(mktemp -d)
    T=$TEST_TMPDIR
    mkdir -p "$T/bin" "$T/stdin"
    : > "$T/argv"
    # shellcheck disable=SC2016
    cat > "$T/bin/ssh" <<'STUB'
#!/bin/bash
[ "$1" = -G ] && { echo "hostname 203.0.113.7"; echo "user root"; exit 0; }
printf '%s\n' "$*" >> "$T/argv"
case "$*" in
    *"id -u"*) echo 0 ;;
    *"stackpilot-backup init"*) [ -n "${INIT_FAIL:-}" ] && exit 1 ;;
    *hostname*) echo srv1 ;;
    *"cat >"*) cat > "$T/stdin/$(date +%s%N)-$RANDOM" ;;
esac
exit 0
STUB
    chmod +x "$T/bin/ssh"
    export T PATH="$T/bin:$PATH" TOOLBOX_LANG=en
    unset INIT_FAIL
}

wizard() { # answers, one per line
    printf '%s\n' "$@" | bash "$REPO_ROOT/local/setup-backup.sh" vps > "$T/out" 2>&1
}

config() { grep -h -l '^RESTIC_REPOSITORY=' "$T"/stdin/* 2>/dev/null | xargs cat 2>/dev/null; }

test_r2_is_default_and_secrets_never_reach_command_line() {
    wizard y "" ACCT my-bucket "" AKID SECRETKEY "" "https://hc.example/ping/1" n
    assert_eq "0" "$?" "wizard succeeds" || cat "$T/out"
    local cfg pw
    cfg=$(config)
    assert_contains "$cfg" "RESTIC_REPOSITORY=s3:https://ACCT.r2.cloudflarestorage.com/my-bucket/srv1" "R2 repository"
    assert_contains "$cfg" "AWS_ACCESS_KEY_ID=AKID" "access key"
    assert_contains "$cfg" "AWS_SECRET_ACCESS_KEY=SECRETKEY" "secret key"
    assert_contains "$cfg" "AWS_DEFAULT_REGION=auto" "R2 region"
    assert_contains "$cfg" "BACKUP_PING_URL=https://hc.example/ping/1" "heartbeat URL"
    pw=$(printf '%s\n' "$cfg" | sed -n 's/^RESTIC_PASSWORD=//p')
    assert_true test "${#pw}" -ge 32
    assert_eq "1" "$(grep -c -- "$pw" "$T/out")" "generated password shown exactly once"
    assert_not_contains "$(cat "$T/argv")" "SECRETKEY" "secret not in ssh arguments"
    assert_not_contains "$(cat "$T/argv")" "$pw" "password not in ssh arguments"
    assert_contains "$(cat "$T/argv")" "chmod 600" "config is private"
    assert_contains "$(cat "$T/argv")" "stackpilot-backup init" "repository initialised"
    assert_not_contains "$(cat "$T/argv")" "stackpilot-backup run" "first backup skipped on request"
    assert_true grep -q -l 'RESTIC_VERSION=' "$T"/stdin/*
}

test_existing_password_is_kept_and_not_echoed() {
    wizard y 1 ACCT my-bucket shared/vps1 AKID SECRETKEY 'old pass!word' ""
    assert_eq "0" "$?" "wizard succeeds" || cat "$T/out"
    assert_contains "$(config)" "my-bucket/shared/vps1" "custom prefix"
    assert_contains "$(config)" "RESTIC_PASSWORD=old\\ pass\\!word" "existing password stored quoted"
    assert_not_contains "$(cat "$T/out")" "old pass!word" "password not echoed"
    assert_not_contains "$(cat "$T/argv")" "stackpilot-backup run" "no automatic backup over an existing repository"
}

test_backblaze_uses_s3_endpoint() {
    wizard y 2 s3.eu-central-003.backblazeb2.com b2-bucket "" KEYID APPKEY "" "" n
    assert_eq "0" "$?" "wizard succeeds" || cat "$T/out"
    assert_contains "$(config)" "RESTIC_REPOSITORY=s3:https://s3.eu-central-003.backblazeb2.com/b2-bucket/srv1" "B2 via S3 API"
    assert_not_contains "$(config)" "AWS_DEFAULT_REGION=auto" "no R2 region for B2"
}

test_generic_s3_with_region() {
    wizard y 3 http://minio.local:9000 bkt "" K S "" "" "" y
    assert_eq "0" "$?" "wizard succeeds" || cat "$T/out"
    assert_contains "$(config)" "RESTIC_REPOSITORY=s3:http://minio.local:9000/bkt/srv1" "S3 repository"
    assert_contains "$(config)" "AWS_DEFAULT_REGION=us-east-1" "default region"
    assert_contains "$(cat "$T/argv")" "stackpilot-backup run" "first backup started"
}

test_sftp_and_local_repositories() {
    wizard y 4 backup@nas.example:/srv/restic/vps "" "" n
    assert_contains "$(config)" "RESTIC_REPOSITORY=sftp:backup@nas.example:/srv/restic/vps" "SFTP repository"
    rm -f "$T"/stdin/*
    wizard y 5 /mnt/backup/restic "" "" n
    assert_contains "$(config)" "RESTIC_REPOSITORY=/mnt/backup/restic" "local repository"
}

test_invalid_choice_and_cancel_write_nothing() {
    wizard y 9
    assert_not_eq "0" "$?" "invalid backend rejected"
    wizard n
    assert_not_eq "0" "$?" "cancel exits non-zero"
    assert_not_contains "$(cat "$T/argv")" "cat >" "nothing written to the server"
}

test_relative_local_path_rejected() {
    wizard y 5 backups/restic
    assert_not_eq "0" "$?" "relative path rejected"
    assert_not_contains "$(cat "$T/argv")" "cat >" "nothing written to the server"
}

test_new_configuration_replaces_old_only_after_init() {
    wizard y 5 /mnt/backup/restic "" "" n
    assert_eq "0" "$?" "wizard succeeds" || cat "$T/out"
    assert_contains "$(cat "$T/argv")" "cat > /opt/stackpilot/config/backup.env.new" "written next to the old one"
    assert_contains "$(cat "$T/argv")" "init && mv -f /opt/stackpilot/config/backup.env.new /opt/stackpilot/config/backup.env" "moved after init"
}

test_failed_init_keeps_current_configuration() {
    INIT_FAIL=1 wizard y 5 /mnt/backup/restic "wrong password" ""
    assert_not_eq "0" "$?" "wizard fails"
    assert_not_contains "$(cat "$T/argv")" "cat > /opt/stackpilot/config/backup.env &&" "current config not overwritten"
    assert_contains "$(cat "$T/argv")" "rm -f /opt/stackpilot/config/backup.env.new" "rejected config removed"
}

test_invalid_heartbeat_url_rejected() {
    wizard y 5 /mnt/backup/restic "" "y"
    assert_not_eq "0" "$?" "non-URL rejected"
    assert_not_contains "$(cat "$T/argv")" "cat >" "nothing written to the server"
}

run_tests "$0"
