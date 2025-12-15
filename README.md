# H.265/HEVC Video Re-encoder

Automated Docker container that finds and re-encodes your largest video files to H.265/HEVC. Designed for Unraid but works anywhere Docker runs.

## Features

- **Autonomous operation** - Set it and forget it. Replaces originals by default with built-in safety checks
- **Smart file selection** - Automatically finds largest non-H.265 files first for maximum space savings
- **Safety-first replacement** - Only replaces originals if new file is at least 10% smaller
- **Persistent caching** - Remembers scanned files between runs, skips already-encoded content
- **GPU acceleration** - Optional NVIDIA NVENC support for faster encoding
- **Detailed logging** - Persistent log file with timestamps and progress tracking

## Quick Start (Unraid)

### Option 1: Docker Hub

1. **Docker** tab → **Add Container**
2. **Repository**: `rsheldiii/h265-reencoder:latest`
3. **Add Path**: Container `/videos` → Host `/mnt/user/your-videos`
4. **Apply**

### Option 2: Template

Copy `unraid-template.xml` to `/boot/config/plugins/dockerMan/templates-user/` and refresh Docker.

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CRF_VALUE` | `20` | Quality (0-51, lower = better). 18-23 recommended |
| `PRESET` | `medium` | Speed/quality tradeoff: `ultrafast` → `veryslow` |
| `NUM_FILES` | `1` | Videos to process per run |
| `MIN_SIZE_REDUCTION` | `10` | Minimum % reduction required to replace original |
| `USE_GPU` | `false` | Enable NVIDIA NVENC (`true`/`false`) |
| `VIDEO_EXTENSIONS` | `.mp4,.mkv,.avi,.wmv,.mov,.flv,.m4v` | File types to scan |
| `LOG_FILE` | `/videos/h265_encoder.log` | Persistent log location |
| `CACHE_FILE` | `/videos/filesize_cache.json` | Scan cache location |

### Post Arguments

| Argument | Description |
|----------|-------------|
| `[number]` | Override `NUM_FILES` (e.g., `5` to process 5 videos) |
| `--no-replace` | Keep original files, create `_h265.mp4` copies instead |
| `--rescan` | Force full directory scan, ignore cache |
| `--dryrun` | Preview what would happen without encoding |

**Examples:**
```
5                    # Process 5 videos, replace originals
3 --no-replace       # Process 3 videos, keep originals  
1 --dryrun --rescan  # Dry run with fresh scan
```

## Safety Features

The container won't blindly replace your files:

1. **Size threshold** - Original only replaced if new file is ≥10% smaller (configurable)
2. **Atomic replacement** - Creates backup before replacing, restores on failure
3. **Codec verification** - Skips files already encoded as H.265/HEVC
4. **Dry run mode** - Test everything before committing

If encoding produces a file that doesn't meet the size threshold, the original is preserved and a new `_h265.mp4` file is created instead.

## GPU Acceleration

Requires [Nvidia-Driver plugin](https://forums.unraid.net/topic/98978-plugin-nvidia-driver/) on Unraid.

1. Set `USE_GPU` to `true`
2. Ensure `--runtime=nvidia` is in Extra Parameters (template includes this)

GPU encoding is significantly faster but may produce slightly larger files at equivalent quality settings.

## Logging

All activity is logged to `/videos/h265_encoder.log` (persists between runs). View it:

- **Unraid share**: `\\YOUR_SERVER\videos\h265_encoder.log`
- **Container console**: `cat /videos/h265_encoder.log`
- **Unraid terminal**: `cat /mnt/user/videos/h265_encoder.log`

## Encoding Settings

```
Codec:     libx265 (CPU) or hevc_nvenc (GPU)
Profile:   main
Tune:      fastdecode
Audio:     copy (passthrough)
Filter:    yadif (deinterlacing)
Keyframes: Adaptive based on framerate (2s GOP)
Container: MP4 with faststart
```

## Local Development

```bash
# Build
docker build -t h265-reencoder .

# Test with dry run
docker run --rm -v ./test-videos:/videos h265-reencoder 1 --dryrun

# Run for real
docker run --rm -v /path/to/videos:/videos h265-reencoder 3
```

## Troubleshooting

**No videos found**: Run with `--rescan` to rebuild cache, or check `VIDEO_EXTENSIONS`

**Encoding fails**: Check container logs for ffmpeg errors. Common issues:
- Insufficient disk space for temp file
- Corrupt source video
- Permission issues on mount

**File not replaced**: Size reduction didn't meet `MIN_SIZE_REDUCTION` threshold. Check logs for details.

**Cache issues**: Delete `/videos/filesize_cache.json` and run with `--rescan`

## License

MIT
