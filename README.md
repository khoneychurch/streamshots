# iPhone Capture Tool

A small macOS desktop app for capturing screenshots and screen recordings from a USB-connected iPhone. Uses the same USB screen-mirror path as QuickTime — not Continuity Camera.

![iPhone Capture Tool](screenshot.png)

## Requirements

- macOS
- Python 3.9+ (system Python works: `/usr/bin/python3`)
- Xcode Command Line Tools (for `swift` and tkinter)

```bash
xcode-select --install
```

If Homebrew Python shows a tkinter error, either install tk support or use system Python:

```bash
brew install python-tk@3.14   # optional, for Homebrew Python only
/usr/bin/python3 app.py       # system Python already includes tkinter
```

## iPhone setup

1. Connect the iPhone with a USB cable (data-capable, not charge-only).
2. Unlock the phone and tap **Trust** when prompted.
3. Keep QuickTime closed while using this app — only one process can use the screen mirror at a time.

## Run

```bash
cd /path/to/streamshots
python3 app.py
```

On first launch, click **Choose Folder…** to pick where captures are saved. The path is remembered in `~/.config/iphone-capture-tool/config.json`.

## Usage

| Action | How |
|---|---|
| Screenshot | **Take Screenshot** button or **Spacebar** |
| Record | **Start Recording** / **Stop Recording** |
| Rescan device | **Refresh** |
| Compress for web | **Convert All to WebP** |

Wait for the status line to show `Ready — [Your Phone Name]` before capturing. The first scan can take a few seconds.

## File naming

Captures use the save folder’s name with a shared incrementing counter. Videos are saved as H.264 MP4 at the original iPhone screen resolution, compressed and optimized for web playback when you stop recording.

```
Lego Builder_00001_pic.png
Lego Builder_00002_video.mp4
Lego Builder_00003_pic.png
```

## Convert All to WebP

Compresses the save folder for web publishing. Clicking **Convert All to WebP** creates a sibling folder named `[foldername]_webp`, converts every PNG to WebP at quality 75, and copies videos (`.mp4`/`.mov`) over unchanged. Originals are never modified. Re-running skips files already in the output folder, so you can capture more shots and convert again to pick up only the new ones.

Requires the `cwebp` encoder:

```bash
brew install webp
```

## Project files

| File | Purpose |
|---|---|
| `app.py` | Tkinter GUI and capture orchestration |
| `ios_screen_helper.swift` | Enables USB screen mirroring and handles AVFoundation capture |

## Troubleshooting

- **No iPhone detected** — Reconnect USB, unlock the phone, trust the Mac, then click **Refresh**.
- **Screenshot timed out** — Click **Refresh** and try again. The helper caches the latest frame, but the mirror must be active first.
- **Input/output error** — Another app (usually QuickTime) is using the phone feed. Quit it and **Refresh**.
- **Black screenshots** — An older version captured Continuity Camera instead of the screen mirror. Make sure you’re on the current code with `ios_screen_helper.swift`.
