#!/bin/bash
# shellcheck disable=SC2034  # SELLF_RELEASE_VERSION is read by the scripts that source this file

# StackPilot - Sellf release verification
# Sourced (never executed) by apps/sellf/install.sh and apps/sellf/update.sh on
# the server. deploy.sh copies this file next to the uploaded script and passes
# its path in SELLF_RELEASE_LIB.
#
# A Sellf release publishes four PM2/tarball assets:
#   sellf-build.tar.gz          the build
#   sellf-build.tar.gz.sha256   sha256sum-style checksum of the build
#   sellf-build.manifest        exactly two LF-terminated lines:
#                                 version=<CalVer, e.g. 2026.9.3>
#                                 sha256=<64 lowercase hex of the build>
#   sellf-build.manifest.sig    raw Ed25519 signature over the manifest bytes
#
# The manifest signature is checked against the public key pinned below, the
# build's hash must equal the signed manifest value, and every archive entry
# must be a plain file or directory inside the extraction root. Anything else
# stops the install/update before a single file is extracted.
#
# Docker installs use two more, separately signed assets instead of the tarball:
#   sellf-image.manifest        exactly two LF-terminated lines:
#                                 version=<CalVer, e.g. 2026.9.3>
#                                 image=ghcr.io/<owner>/sellf@sha256:<64 lowercase hex>
#   sellf-image.manifest.sig    raw Ed25519 signature over the manifest bytes,
#                                with the SAME key as the tarball manifest
#
# Line 2 starts with "image=" (never "sha256="), so the tarball and image
# manifests are disjoint: a signed manifest of one shape is never accepted by
# the other shape's parser, even though both are signed by the same key.
#
# Functions return non-zero on failure and print the reason to stderr; they
# never exit, so callers decide how to stop.

# ===== SELLF RELEASE PUBLIC KEY =====
# Ed25519 public key of the Sellf release pipeline. This is the only copy in
# stackpilot; replace it only between the markers. If it is ever reset to the
# REPLACE_WITH_SELLF_RELEASE_PUBLIC_KEY placeholder, every download is refused.
# sellf-release-key:start
SELLF_RELEASE_PUBKEY=$(cat <<'PEM'
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEA02w9x0hle3SJILFgdRo5vqykMVohu4XRQw4F9awhsuc=
-----END PUBLIC KEY-----
PEM
)
# sellf-release-key:end

SELLF_RELEASE_ASSETS="sellf-build.tar.gz sellf-build.tar.gz.sha256 sellf-build.manifest sellf-build.manifest.sig"
SELLF_IMAGE_ASSETS="sellf-image.manifest sellf-image.manifest.sig"

_sellf_release_error() {
    echo "❌ $*" >&2
}

_sellf_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

_sellf_is_calver() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

sellf_ensure_system_path() {
    local SYSTEM_BIN="${1:-/usr/local/bin}" BINARY SOURCE_BIN
    export PATH="${BUN_INSTALL:-$HOME/.bun}/bin:$PATH"
    mkdir -p "$SYSTEM_BIN"
    for BINARY in bun pm2; do
        if [ -e "$SYSTEM_BIN/$BINARY" ]; then
            continue
        fi
        SOURCE_BIN=$(command -v "$BINARY") || return 1
        [ -x "$SOURCE_BIN" ] || return 1
        ln -sfn "$SOURCE_BIN" "$SYSTEM_BIN/$BINARY" || return 1
    done
}

# sellf_release_base_url REPO — prints the download base URL of the newest
# release, e.g. https://github.com/owner/repo/releases/download/v2026.9.3.
# Resolving the tag once keeps all four assets from the same release.
sellf_release_base_url() {
    local repo="$1" url tag=""
    url=$(curl -fsSL --proto '=https' --proto-redir '=https' -o /dev/null \
        -w '%{url_effective}' "https://github.com/$repo/releases/latest" 2>/dev/null) || url=""
    case "$url" in
        */releases/tag/*) tag="${url##*/releases/tag/}" ;;
    esac
    if [ -z "$tag" ]; then
        # No release marked "latest": take the newest release that has a manifest.
        tag=$(curl -fsSL --proto '=https' "https://api.github.com/repos/$repo/releases" 2>/dev/null \
            | grep -m1 '"browser_download_url": *".*/sellf-build\.manifest"' \
            | sed 's|.*/releases/download/\([^/]*\)/.*|\1|')
    fi
    if ! [[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]]; then
        _sellf_release_error "Could not find a Sellf release in $repo"
        return 1
    fi
    echo "https://github.com/$repo/releases/download/$tag"
}

# _sellf_download_assets DIR BASE_URL ASSETS — downloads each of ASSETS
# (space-separated file names) from BASE_URL into DIR.
_sellf_download_assets() {
    local dir="$1" base="$2" assets="$3" asset
    for asset in $assets; do
        if ! curl -fsSL --proto '=https' --proto-redir '=https' -o "$dir/$asset" "$base/$asset"; then
            _sellf_release_error "Failed to download $asset from $base"
            return 1
        fi
    done
}

# sellf_download_release DIR BASE_URL — downloads the four tarball release
# assets into DIR (a private directory created by the caller).
sellf_download_release() {
    _sellf_download_assets "$1" "$2" "$SELLF_RELEASE_ASSETS"
}

# sellf_download_image_manifest DIR BASE_URL — downloads the signed image
# manifest + signature into DIR, from the same release BASE_URL as the
# tarball assets (see sellf_release_base_url).
sellf_download_image_manifest() {
    _sellf_download_assets "$1" "$2" "$SELLF_IMAGE_ASSETS"
}

# sellf_parse_manifest FILE — sets SELLF_MANIFEST_VERSION and SELLF_MANIFEST_SHA256.
# The file must be exactly "version=<calver>\nsha256=<hex>\n", nothing more.
sellf_parse_manifest() {
    local file="$1" line1 line2 version sha lines bytes
    SELLF_MANIFEST_VERSION=""
    SELLF_MANIFEST_SHA256=""
    line1=$(sed -n 1p "$file")
    line2=$(sed -n 2p "$file")
    version="${line1#version=}"
    sha="${line2#sha256=}"
    lines=$(wc -l < "$file" | tr -d ' ')
    bytes=$(wc -c < "$file" | tr -d ' ')
    if [ "$line1" != "version=$version" ] || [ "$line2" != "sha256=$sha" ] \
        || ! _sellf_is_calver "$version" || ! [[ "$sha" =~ ^[0-9a-f]{64}$ ]] \
        || [ "$lines" != "2" ] || [ "$bytes" != "$(( ${#line1} + ${#line2} + 2 ))" ]; then
        _sellf_release_error "Release manifest is not in the expected format (version=, sha256=)"
        return 1
    fi
    SELLF_MANIFEST_VERSION="$version"
    SELLF_MANIFEST_SHA256="$sha"
}

# sellf_validate_archive FILE — every entry must be a regular file or a
# directory (tar -tzvf type char) with a relative path that stays inside the
# extraction root (tar -tzf). Runs BEFORE extraction.
sellf_validate_archive() {
    local archive="$1" listing paths line entry_type entry_path
    if ! listing=$(tar -tzvf "$archive" 2>/dev/null) || ! paths=$(tar -tzf "$archive" 2>/dev/null) \
        || [ -z "$paths" ]; then
        _sellf_release_error "Archive cannot be read: $archive"
        return 1
    fi
    while IFS= read -r line; do
        entry_type="${line:0:1}"
        case "$entry_type" in
            -|d) ;;
            *)
                _sellf_release_error "Archive contains an entry of type '$entry_type' (only files and directories are allowed)"
                return 1
                ;;
        esac
    done <<< "$listing"
    while IFS= read -r entry_path; do
        case "$entry_path" in
            /*|..|../*|*/..|*/../*)
                _sellf_release_error "Archive contains a path outside the install directory: $entry_path"
                return 1
                ;;
        esac
    done <<< "$paths"
}

# sellf_verify_release DIR — checks the downloaded release in DIR and sets
# SELLF_RELEASE_VERSION from the signed manifest.
sellf_verify_release() {
    local dir="$1" asset pubkey_file checksum actual
    SELLF_RELEASE_VERSION=""

    for asset in $SELLF_RELEASE_ASSETS; do
        if [ ! -s "$dir/$asset" ]; then
            _sellf_release_error "Release asset missing: $asset"
            return 1
        fi
    done

    if [[ "$SELLF_RELEASE_PUBKEY" == *REPLACE_WITH_SELLF_RELEASE_PUBLIC_KEY* ]]; then
        _sellf_release_error "Sellf release public key is not configured in apps/sellf/release-verify.sh — cannot verify the release"
        return 1
    fi

    pubkey_file="$dir/sellf-release.pub.pem"
    printf '%s\n' "$SELLF_RELEASE_PUBKEY" > "$pubkey_file"
    if [[ "$(openssl pkey -pubin -in "$pubkey_file" -noout -text 2>/dev/null)" != *ED25519* ]]; then
        _sellf_release_error "openssl on this server cannot read the Ed25519 release key (OpenSSL 3.0 or newer is required)"
        return 1
    fi
    if ! openssl pkeyutl -verify -pubin -inkey "$pubkey_file" -rawin \
        -in "$dir/sellf-build.manifest" -sigfile "$dir/sellf-build.manifest.sig" >/dev/null 2>&1; then
        _sellf_release_error "Release manifest signature is not valid for the Sellf release key"
        return 1
    fi

    sellf_parse_manifest "$dir/sellf-build.manifest" || return 1

    checksum=$(awk 'NR==1{print $1}' "$dir/sellf-build.tar.gz.sha256")
    if [ "$checksum" != "$SELLF_MANIFEST_SHA256" ]; then
        _sellf_release_error "sellf-build.tar.gz.sha256 does not match the signed manifest checksum"
        return 1
    fi
    actual=$(_sellf_sha256 "$dir/sellf-build.tar.gz")
    if [ "$actual" != "$SELLF_MANIFEST_SHA256" ]; then
        _sellf_release_error "sellf-build.tar.gz checksum does not match the signed manifest"
        return 1
    fi

    sellf_validate_archive "$dir/sellf-build.tar.gz" || return 1

    SELLF_RELEASE_VERSION="$SELLF_MANIFEST_VERSION"
}

# ===== SELLF IMAGE MANIFEST (Docker installs) =====
# Docker installs never pull a mutable ":latest" tag: they verify a signed
# sellf-image.manifest (same key as the tarball manifest, disjoint format —
# see the file header) and pull the image strictly by the digest it names.

# sellf_parse_image_manifest FILE — sets SELLF_IMAGE_MANIFEST_VERSION and
# SELLF_IMAGE_MANIFEST_REF. The file must be exactly
# "version=<calver>\nimage=<ref>\n", nothing more.
sellf_parse_image_manifest() {
    local file="$1" line1 line2 version image lines bytes
    SELLF_IMAGE_MANIFEST_VERSION=""
    SELLF_IMAGE_MANIFEST_REF=""
    line1=$(sed -n 1p "$file")
    line2=$(sed -n 2p "$file")
    version="${line1#version=}"
    image="${line2#image=}"
    lines=$(wc -l < "$file" | tr -d ' ')
    bytes=$(wc -c < "$file" | tr -d ' ')
    if [ "$line1" != "version=$version" ] || [ "$line2" != "image=$image" ] || [ -z "$image" ] \
        || ! _sellf_is_calver "$version" \
        || [ "$lines" != "2" ] || [ "$bytes" != "$(( ${#line1} + ${#line2} + 2 ))" ]; then
        _sellf_release_error "Image manifest is not in the expected format (version=, image=)"
        return 1
    fi
    SELLF_IMAGE_MANIFEST_VERSION="$version"
    SELLF_IMAGE_MANIFEST_REF="$image"
}

# sellf_verify_image_manifest DIR EXPECTED_REPO — checks the downloaded image
# manifest in DIR (signature, strict format, CalVer version) and requires the
# image reference to be exactly EXPECTED_REPO ("ghcr.io/<owner>/sellf") at a
# sha256 digest — never a tag, never another registry or repo. On success sets
# SELLF_IMAGE_REF and SELLF_RELEASE_VERSION.
sellf_verify_image_manifest() {
    local dir="$1" expected_repo="$2" asset pubkey_file prefix digest
    SELLF_IMAGE_REF=""
    SELLF_RELEASE_VERSION=""

    for asset in $SELLF_IMAGE_ASSETS; do
        if [ ! -s "$dir/$asset" ]; then
            _sellf_release_error "Image manifest asset missing: $asset"
            return 1
        fi
    done

    if [[ "$SELLF_RELEASE_PUBKEY" == *REPLACE_WITH_SELLF_RELEASE_PUBLIC_KEY* ]]; then
        _sellf_release_error "Sellf release public key is not configured in apps/sellf/release-verify.sh — cannot verify the image manifest"
        return 1
    fi

    pubkey_file="$dir/sellf-release.pub.pem"
    printf '%s\n' "$SELLF_RELEASE_PUBKEY" > "$pubkey_file"
    if [[ "$(openssl pkey -pubin -in "$pubkey_file" -noout -text 2>/dev/null)" != *ED25519* ]]; then
        _sellf_release_error "openssl on this server cannot read the Ed25519 release key (OpenSSL 3.0 or newer is required)"
        return 1
    fi
    if ! openssl pkeyutl -verify -pubin -inkey "$pubkey_file" -rawin \
        -in "$dir/sellf-image.manifest" -sigfile "$dir/sellf-image.manifest.sig" >/dev/null 2>&1; then
        _sellf_release_error "Image manifest signature is not valid for the Sellf release key"
        return 1
    fi

    sellf_parse_image_manifest "$dir/sellf-image.manifest" || return 1

    prefix="${expected_repo}@sha256:"
    case "$SELLF_IMAGE_MANIFEST_REF" in
        "$prefix"*)
            digest="${SELLF_IMAGE_MANIFEST_REF#"$prefix"}"
            if ! [[ "$digest" =~ ^[0-9a-f]{64}$ ]]; then
                _sellf_release_error "Image manifest digest is not a valid sha256 hex digest: $SELLF_IMAGE_MANIFEST_REF"
                return 1
            fi
            ;;
        *)
            _sellf_release_error "Image manifest does not point at $expected_repo by digest: $SELLF_IMAGE_MANIFEST_REF"
            return 1
            ;;
    esac

    SELLF_IMAGE_REF="$SELLF_IMAGE_MANIFEST_REF"
    SELLF_RELEASE_VERSION="$SELLF_IMAGE_MANIFEST_VERSION"
}

# sellf_extract_docker_migrations IMAGE_REF DEST_DIR — copies supabase/
# (migrations + templates) out of a pulled, verified image into
# DEST_DIR/supabase, via a throwaway container that is never started. Docker
# installs get migrations that match the running image, not an unsigned
# GitHub `main` checkout.
sellf_extract_docker_migrations() {
    local image_ref="$1" dest_dir="$2" cid
    if ! cid=$(docker create "$image_ref" 2>/dev/null) || [ -z "$cid" ]; then
        _sellf_release_error "Failed to create a container from $image_ref to extract migrations"
        return 1
    fi
    mkdir -p "$dest_dir/supabase"
    if ! docker cp "$cid:/app/supabase/." "$dest_dir/supabase/" 2>/dev/null; then
        _sellf_release_error "Failed to copy supabase/ out of $image_ref"
        docker rm -f "$cid" >/dev/null 2>&1 || true
        return 1
    fi
    docker rm -f "$cid" >/dev/null 2>&1 || true
}

# sellf_write_docker_compose STACK_DIR IMAGE_REF CONTAINER_NAME — writes
# docker-compose.yml pinned to a verified digest. The Watchtower opt-out label
# is required: a digest-pinned container must never be silently replaced by a
# background updater.
sellf_write_docker_compose() {
    local stack_dir="$1" image_ref="$2" container_name="$3"
    cat > "$stack_dir/docker-compose.yml" <<DCEOF
services:
  sellf:
    image: ${image_ref}
    container_name: ${container_name}
    restart: unless-stopped
    network_mode: host
    env_file: .env
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/api/health').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    labels:
      com.centurylinklabs.watchtower.enable: "false"
DCEOF
}

# sellf_docker_deploy GITHUB_REPO STACK_DIR MIGRATIONS_DEST CONTAINER_NAME CURRENT_VERSION
#
# The one Docker install/update path, shared by install.sh and update.sh:
#   1. resolve the newest GitHub release (sellf_release_base_url)
#   2. download + verify the signed sellf-image.manifest (never :latest)
#   3. refuse a downgrade against CURRENT_VERSION (sellf_check_update_version)
#   4. docker pull the image strictly by digest
#   5. require the pulled image's own org.opencontainers.image.version label
#      to equal the signed manifest version (defense in depth)
#   6. extract supabase/ from the verified image into MIGRATIONS_DEST
#   7. write STACK_DIR/docker-compose.yml pinned to the digest
#
# Never runs `docker compose up`/`down` — the caller decides when to (re)start.
# Sets SELLF_IMAGE_REF and SELLF_RELEASE_VERSION on success.
sellf_docker_deploy() {
    local github_repo="$1" stack_dir="$2" migrations_dest="$3" container_name="$4" current_version="$5"
    local repo_lower expected_repo base_url dir label

    SELLF_IMAGE_REF=""
    SELLF_RELEASE_VERSION=""

    repo_lower=$(printf '%s' "$github_repo" | tr '[:upper:]' '[:lower:]')
    expected_repo="ghcr.io/$repo_lower"

    base_url=$(sellf_release_base_url "$github_repo") || return 1

    dir=$(mktemp -d)
    trap "rm -rf '$dir'" RETURN

    sellf_download_image_manifest "$dir" "$base_url" || return 1
    sellf_verify_image_manifest "$dir" "$expected_repo" || return 1
    sellf_check_update_version "$current_version" "$SELLF_RELEASE_VERSION" || return 1

    if ! docker pull "$SELLF_IMAGE_REF"; then
        _sellf_release_error "Failed to pull image: $SELLF_IMAGE_REF"
        return 1
    fi

    label=$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$SELLF_IMAGE_REF" 2>/dev/null) || label=""
    if [ "$label" != "$SELLF_RELEASE_VERSION" ]; then
        _sellf_release_error "Pulled image reports version '$label', signed manifest says '$SELLF_RELEASE_VERSION' — refusing"
        return 1
    fi

    sellf_extract_docker_migrations "$SELLF_IMAGE_REF" "$migrations_dest" || return 1
    sellf_write_docker_compose "$stack_dir" "$SELLF_IMAGE_REF" "$container_name" || return 1
}

# ===== SELLF REQUIRED SECRETS (install.sh + update.sh, PM2 and Docker) =====
# One shared place that guarantees every secret/flag Sellf's production
# startup assertions require exists in the instance's env file, whichever
# runtime and whichever code path (fresh install, update, or restart) got
# there. Keep this in sync with
# admin-panel/src/lib/security/startup-assertions.ts: a new required secret
# there needs a matching block here, or a Docker install/update can pick up a
# release that refuses to boot without it ever generating it.

# sellf_ensure_required_secrets ENV_FILE — idempotently fills in every
# required secret/flag that is missing from ENV_FILE. Never overwrites an
# existing value (including an operator-set empty one or a legacy alias),
# never prints a generated value — only the name of what it generated.
#
# Callers are responsible for propagating ENV_FILE's content to wherever the
# running process actually reads its env from: PM2 re-sources .env.local on
# every start, Docker reads .env (refreshed from .env.local by the caller,
# see apps/sellf/update.sh and install.sh).
sellf_ensure_required_secrets() {
    local env_file="$1"

    if [ ! -f "$env_file" ]; then
        _sellf_release_error "sellf_ensure_required_secrets: env file not found: $env_file"
        return 1
    fi

    # AES-256-GCM key for every DB-stored secret (Stripe UI-wizard key,
    # webhook signing secret, GUS / Currency API keys, license-issuer keys).
    # Without it the admin cannot save integration settings and encrypted
    # secrets fail to decrypt (assertAppEncryptionKey). Guard on BOTH names:
    # legacy installs may carry the old STRIPE_ENCRYPTION_KEY (which the app
    # still honours as a fallback) — adding a fresh APP_ENCRYPTION_KEY there
    # would shadow it and make existing ciphertext undecryptable. NEVER
    # rotate after first set.
    if ! grep -qE "^(APP_ENCRYPTION_KEY|STRIPE_ENCRYPTION_KEY)=" "$env_file"; then
        printf "\nAPP_ENCRYPTION_KEY=%s\n" "$(openssl rand -base64 32)" >> "$env_file"
        echo "   🔐 generated APP_ENCRYPTION_KEY (DO NOT change — encrypts DB secrets)"
    fi

    # Server-side HMAC secret binding checkout metadata mutations to the
    # Stripe session they were created for. Production refuses to boot
    # without it (assertCheckoutBindingSecret). Existing values are left
    # alone so in-flight checkout sessions stay valid.
    if ! grep -q "^CHECKOUT_BINDING_SECRET=" "$env_file"; then
        printf "\nCHECKOUT_BINDING_SECRET=%s\n" "$(openssl rand -base64 32)" >> "$env_file"
        echo "   🔐 generated CHECKOUT_BINDING_SECRET (rotate via incident response only)"
    fi

    # HMAC key for the per-product login-wall handoff token. Rotating
    # invalidates in-flight tokens; visitors transparently get a fresh one
    # via /loginwall/protect.
    if ! grep -q "^LOGINWALL_SECRET=" "$env_file"; then
        printf "\nLOGINWALL_SECRET=%s\n" "$(openssl rand -hex 32)" >> "$env_file"
        echo "   🔐 generated LOGINWALL_SECRET"
    fi

    # Bearer token for /api/cron. Without it every request is rejected and
    # scheduled jobs (access-expired webhooks, webhook log cleanup) never
    # run.
    if ! grep -q "^CRON_SECRET=" "$env_file"; then
        printf "\nCRON_SECRET=%s\n" "$(openssl rand -base64 32)" >> "$env_file"
        echo "   🔐 generated CRON_SECRET (point your scheduler at /api/cron with Authorization: Bearer <value>)"
    fi

    # Self-hosted ALTCHA captcha (HMAC proof-of-work, no external account),
    # bot protection on signup/checkout out of the box. Skip if Turnstile is
    # already configured — it takes priority, so generating ALTCHA there
    # would be dead config. Without any captcha key, forms have no bot
    # protection.
    if ! grep -qE "^(ALTCHA_HMAC_KEY|CLOUDFLARE_TURNSTILE_SECRET_KEY)=" "$env_file"; then
        printf "\nALTCHA_HMAC_KEY=%s\n" "$(openssl rand -hex 32)" >> "$env_file"
        echo "   🔐 generated ALTCHA_HMAC_KEY (self-hosted captcha; Turnstile overrides if you set it)"
    fi

    # Production startup refuses to boot without it (assertTrustedProxyConfig);
    # rate limiting also degrades to a shared "unknown" bucket for every
    # request without it. Stackpilot always deploys behind Caddy as the
    # public entrypoint, so this is the correct topology.
    if ! grep -q "^TRUSTED_PROXY=" "$env_file"; then
        printf "\nTRUSTED_PROXY=true\n" >> "$env_file"
        echo "   🔒 enabled TRUSTED_PROXY (read client IP from last X-Forwarded-For hop)"
    fi
}

# sellf_check_update_version INSTALLED CANDIDATE
#   0 = candidate is newer or the same (re-deploy), or installed version unknown: proceed
#   1 = candidate is older or not a valid version: refuse
# CalVer YYYY.M.patch is compared numerically per component.
sellf_check_update_version() {
    local installed candidate i a b
    installed=$(printf '%s' "$1" | tr -d '[:space:]')
    installed="${installed#v}"
    candidate="$2"

    if ! _sellf_is_calver "$candidate"; then
        _sellf_release_error "Release version '$candidate' is not a valid version"
        return 1
    fi
    if ! _sellf_is_calver "$installed"; then
        echo "⚠️  Installed Sellf version is unknown — cannot compare with $candidate, continuing" >&2
        return 0
    fi

    local -a iv cv
    IFS=. read -r -a iv <<< "$installed"
    IFS=. read -r -a cv <<< "$candidate"
    for i in 0 1 2; do
        a=$((10#${iv[$i]}))
        b=$((10#${cv[$i]}))
        if [ "$b" -gt "$a" ]; then
            return 0
        elif [ "$b" -lt "$a" ]; then
            _sellf_release_error "Release $candidate is older than the installed version $installed — refusing to downgrade"
            return 1
        fi
    done
    echo "   Re-deploying the installed version $candidate"
}
