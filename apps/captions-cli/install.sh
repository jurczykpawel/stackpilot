#!/bin/bash

# StackPilot - captions-cli
# Burn word-level karaoke captions onto videos. Local Whisper + ffmpeg.
# Zero SaaS, zero monthly fee. The Submagic / CapCut Pro you self-host.
# https://github.com/jurczykpawel/captions-cli
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=870   # ghcr.io/jurczykpawel/captions-cli:slim — ASS engine only
# IMAGE_SIZE_MB_FULL=1600 # :full — adds Hyperframes/Chromium for CSS-perfect glow
#
# This is NOT a long-running service. captions-cli is a one-shot CLI:
# you SSH into the box, run `captions video.mp4 --preset hormozi`, and
# get back `video-captioned.mp4`. The installer pulls the Docker image
# and drops a wrapper at /usr/local/bin/captions so the user types a
# native-feeling command instead of a 3-line `docker run`.
#
# Optional environment variables:
#   VARIANT  - "slim" (default, ASS engine, 870 MB) | "full" (ASS+HF, 1.6 GB).
#              Pick "full" only if you need CSS-perfect glow/blur.
#   IMAGE    - override the docker image entirely (advanced).

set -e

APP_NAME="captions-cli"
STACK_DIR="/opt/stacks/$APP_NAME"
VARIANT="${VARIANT:-slim}"
IMAGE="${IMAGE:-ghcr.io/jurczykpawel/captions-cli:$VARIANT}"
WRAPPER="/usr/local/bin/captions"
WORK_DIR="${CAPTIONS_WORK_DIR:-$HOME/captions}"

echo "--- 🎬 captions-cli Setup ---"
echo "Burn karaoke captions onto videos. Local Whisper + ffmpeg."
echo ""
echo "Variant: $VARIANT"
echo "Image:   $IMAGE"
echo ""

# Pull the image so the first user-run doesn't pay the download.
echo "📥 Pulling Docker image (one-time, ~$([ "$VARIANT" = "slim" ] && echo "870 MB" || echo "1.6 GB"))…"
sudo docker pull "$IMAGE"

# Persistent named volume for the Whisper model + any browser cache (HF).
sudo docker volume create captions-cache >/dev/null

# Default working directory the wrapper mounts as /work in the container.
# User drops .mp4 files here, gets *-captioned.mp4 back.
mkdir -p "$WORK_DIR"

# Wrapper script — makes `captions video.mp4` work as if the binary were
# native. Mounts CWD as /work, so relative paths "just work":
#
#   cd ~/captions && captions reel.mp4 --preset hormozi --lang pl
#
# Uses --rm so containers don't pile up. Persists the model cache.
sudo tee "$WRAPPER" >/dev/null <<EOF
#!/bin/bash
# captions-cli wrapper — installed by stackpilot.
# Runs the captions container against the current working directory.
exec sudo docker run --rm \\
  -v "\$(pwd):/work" \\
  -v captions-cache:/data \\
  "$IMAGE" "\$@"
EOF
sudo chmod +x "$WRAPPER"

# Stack dir holds the install marker so stackpilot's app-list / uninstall
# scripts can see this app exists (by convention every installed app has
# /opt/stacks/<name>).
sudo mkdir -p "$STACK_DIR"
echo "$IMAGE" | sudo tee "$STACK_DIR/image" >/dev/null
echo "$VARIANT" | sudo tee "$STACK_DIR/variant" >/dev/null

cat <<EOF

✅ captions-cli installed.

USAGE
  cd $WORK_DIR                # or any folder with your videos
  captions reel.mp4                                       # default look (outline-pop)
  captions reel.mp4 --preset hormozi --lang pl
  captions reel.mp4 --preset single-word
  captions --list-presets

The wrapper mounts your current directory as the work folder, so input
+ output files live next to each other on disk.

Whisper downloads its model (~140 MB) on the first run into the
'captions-cache' Docker volume — subsequent runs are instant.

DOCS
  captions --help
  https://github.com/jurczykpawel/captions-cli

UNINSTALL
  sudo rm $WRAPPER
  sudo rm -rf $STACK_DIR
  sudo docker rmi $IMAGE
  sudo docker volume rm captions-cache
EOF
