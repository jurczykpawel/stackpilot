#!/bin/bash

# The upstream minio/minio image is gone from Docker Hub; every installer that
# bundles MinIO must use the same pinned, maintained image.

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

source "$TESTS_DIR/test-runner.sh"

PINNED_IMAGE="pgsty/silo:RELEASE.2026-11-12T00-00-00Z"

minio_images() {
    grep -h -E '^[[:space:]]*image:[[:space:]]*[^[:space:]]*(minio|silo)' "$REPO_ROOT"/apps/*/install.sh |
        sed -E 's/^[[:space:]]*image:[[:space:]]*//'
}

test_no_installer_uses_the_removed_upstream_image() {
    assert_not_contains "$(minio_images)" "minio/minio" "no installer pulls minio/minio"
}

test_every_bundled_minio_uses_the_pinned_image() {
    local images
    images=$(minio_images | sort -u)
    assert_eq "$PINNED_IMAGE" "$images" "minio, cap and plunk share one pinned image"
    assert_eq "3" "$(minio_images | wc -l | tr -d ' ')" "all three MinIO services found"
}

test_minio_readme_names_the_pinned_image() {
    assert_contains "$(cat "$REPO_ROOT/apps/minio/README.md")" "$PINNED_IMAGE" "README documents the image choice"
}

run_tests "$0"
