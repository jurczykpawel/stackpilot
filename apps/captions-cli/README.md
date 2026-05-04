# captions-cli

**Burn word-level karaoke captions onto videos. Local Whisper + ffmpeg. Zero SaaS.**

What you get instead of paying Submagic 19-69 USD/month: a one-shot CLI on your VPS that
takes any MP4 and adds an animated caption overlay. 41-second clip captions in ~7 seconds
on the slim image.

```bash
captions reel.mp4 --preset hormozi --lang pl
# → reel-captioned.mp4
```

## Install

```bash
./local/deploy.sh captions-cli                       # default: slim (870 MB)
VARIANT=full ./local/deploy.sh captions-cli          # if you need HF engine
```

The installer:
- pulls `ghcr.io/jurczykpawel/captions-cli:slim|full`
- creates `/usr/local/bin/captions` wrapper that mounts CWD as `/work`
- creates the `captions-cache` Docker volume for the Whisper model

## Variants

| `VARIANT` | Image size | Engine | Render speed (41 s clip) | Min RAM |
|---|---|---|---|---|
| `slim` *(default)* | 870 MB | ASS (ffmpeg+libass) | ~3 s | 1 GB |
| `full` | 1.6 GB | ASS + HF (ffmpeg+libass+Hyperframes/Chromium) | ~40 s for HF | 2 GB |

Pick `slim` unless you specifically need `--engine hf` for CSS-perfect glow blur or 3-D
transforms. For lead-magnet / standard reel captions, slim is identical-looking and
10× faster.

## Usage

After install, you SSH into the box and just run:

```bash
ssh user@vps
cd ~/captions                                   # any folder with .mp4 files
captions reel.mp4                               # default outline-pop, English
captions reel.mp4 --preset hormozi --lang pl    # Polish, Hormozi look
captions reel.mp4 --preset single-word          # Submagic-style 1 word at a time
captions reel.mp4 --engine hf --preset glow     # CSS-perfect glow (full image only)
captions --list-presets                         # see all 9 looks
captions --help
```

Output lands next to the input as `<name>-captioned.mp4`.

## Presets (9, all free)

`outline-pop` (default) · `hormozi` · `pop-word` · `pill` · `glow` · `underline-sweep` ·
`box-highlight` · `single-word` · `text`

See `captions --list-presets` for descriptions.

## How it works

The wrapper at `/usr/local/bin/captions` boils down to:

```bash
docker run --rm -v "$(pwd):/work" -v captions-cache:/data <image> "$@"
```

- CWD is mounted as `/work` inside the container so relative paths "just work"
- The `captions-cache` Docker volume persists the Whisper model (~140 MB) between runs
- `--rm` keeps containers from piling up

## RAM

| Variant | Idle | While rendering |
|---|---|---|
| `slim` | 0 (image only) | ~500 MB peak (ffmpeg+whisper concurrent) |
| `full` | 0 | ~1.5-2 GB peak (Chromium for HF) |

`slim` is fine on a 1 GB VPS (e.g. mikrus). `full` wants 2 GB+.

## Whisper models

The first run auto-downloads `ggml-base.bin` (~140 MB) into the `captions-cache` volume.
For better accuracy on Polish or proper nouns, override per-call:

```bash
captions reel.mp4 --whisper-model ggml-large-v3-turbo.bin --lang pl
```

Larger model = larger one-time download (1.5 GB for turbo) but identical wrapper.

## Updates

```bash
sudo docker pull ghcr.io/jurczykpawel/captions-cli:slim    # or :full
```

The wrapper auto-uses the latest tag, so no re-install needed.

## Uninstall

```bash
sudo rm /usr/local/bin/captions
sudo rm -rf /opt/stacks/captions-cli
sudo docker rmi ghcr.io/jurczykpawel/captions-cli:slim     # or :full
sudo docker volume rm captions-cache
```

## See also

- Source: <https://github.com/jurczykpawel/captions-cli>
- Lead magnet (Polish): `napisy-do-video-lokalnie.md` w vault TSA
