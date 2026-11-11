# Grabit Launcher

A Noctalia plugin that launches [grabit](https://heliopolis.live/creations/grabit) for screenshots, screen recording, OCR, and uploads.

grabit handles the interactive UI (region selector, annotator, recording control bar). This plugin provides a bar button, a mode menu, and recording-state mirroring — so grabit feels like a native part of the shell.

## Features

- **Bar widget** with gesture-based capture modes
- **Right-click menu** for all grabit capture modes
- **Recording state mirroring** — the widget shows live recording status
- **Recording indicator layer** — thin red bar at screen top while recording
- **Control-center shortcut** — capture from the control center
- **Settings panel** — configure grabit behavior

## Widget Gestures

| Gesture | Action | grabit flag |
|---------|--------|-------------|
| Left click | Default capture (region → clipboard) | `-c` |
| Right click | Open mode menu | — |
| Middle click | Last region | `-L` |
| Scroll up | Fullscreen | `-F` |
| Scroll down | Window | `-w` |

## Mode Menu

Right-click the widget to access all capture modes:

- Region (copy / save / upload)
- Fullscreen
- Window
- Last region
- Annotate
- OCR to clipboard
- Pin to desktop
- Start recording
- Settings...

## Requirements

- [grabit](https://heliopolis.live/creations/grabit) installed on `PATH`
- Noctalia v5+ with plugin support

## Installation

Add this as a git source in Noctalia Settings → Plugins:

```
https://github.com/snowballons/grabit
```

Or copy to your local plugins directory:

```bash
cp -r grabit ~/.local/share/noctalia/plugins/
```

## License

MIT