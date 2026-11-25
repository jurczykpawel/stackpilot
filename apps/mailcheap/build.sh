#!/bin/bash
# Build on the operator's computer, never on a small VPS.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_REF="${SOURCE_REF:-f8b0b7fbc93ce09c1221c8bdc073b729c0efe237}"
PLATFORM="${PLATFORM:-linux/amd64}"
OUTPUT="${1:-$PWD/mailcheap-image.tar}"
case "$SOURCE_REF" in *[!0-9a-f]*|'') echo 'SOURCE_REF must be a full commit SHA.' >&2; exit 1 ;; esac
[ "${#SOURCE_REF}" -eq 40 ] || { echo 'SOURCE_REF must be a full commit SHA.' >&2; exit 1; }
BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT
curl -fsSL "https://codeload.github.com/marclou/mailcheap/tar.gz/$SOURCE_REF" | tar -xz --strip-components=1 -C "$BUILD_DIR"
cp "$SCRIPT_DIR/Dockerfile" "$BUILD_DIR/Dockerfile"
docker build --platform "$PLATFORM" --build-arg "SOURCE_REF=$SOURCE_REF" -t "stackpilot/mailcheap:$SOURCE_REF" "$BUILD_DIR"
docker save -o "$OUTPUT" "stackpilot/mailcheap:$SOURCE_REF"
echo "Image archive: $OUTPUT ($PLATFORM); deploy using local/deploy.sh mailcheap --build-file=$OUTPUT."
