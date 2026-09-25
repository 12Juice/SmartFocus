# SmartFocus

A macOS menu bar app that restores keyboard focus when the frontmost window closes.

macOS sometimes drops focus to the Desktop/Finder after you close a window. SmartFocus detects that focus vacuum and activates the topmost remaining usable window instead.

## Features

- **Focus restoration** on window close (Cmd+W), with minimal interference: if macOS already falls back to a usable app, SmartFocus accepts it and does nothing
- **Event-driven**: `NSWorkspace` notifications trigger short high-frequency detection bursts; a low-frequency fallback timer (default 0.2s) covers no-event cases (e.g. Chrome/VS Code closing their last window without quitting)
- **Hot-reloaded config** at `~/.smartfocus/config.json` (poll interval, app blacklist, debug logging), survives atomic saves
- Built-in **log console** with debug/error levels (errors only, unless debug logging is on)
- **Launch at login** (macOS 13+ via `SMAppService`)
- **Screen-recording permission watchdog**: menu bar turns into ⚠️ when the permission is lost, with recovery detection

## Build & Package

```bash
./build.sh          # produces build/SmartFocus.app (ad-hoc signed)
./package.sh        # additionally produces build/SmartFocus-<version>.dmg
                    # (drag-to-install layout with an /Applications symlink)
```

Requires Xcode Command Line Tools. Grant **Screen Recording** permission (System Settings → Privacy & Security) on first launch.

## Install

Open the DMG and drag SmartFocus to Applications — or directly:

```bash
cp -R build/SmartFocus.app /Applications/
```

Note: with ad-hoc signing, re-building invalidates the registered login item and TCC grants — re-toggle them after upgrading, or sign with a stable local certificate. The DMG is not notarized (no Developer ID certificate); on other machines Gatekeeper will challenge it — right-click → Open, then confirm.

## Config

`~/.smartfocus/config.json`:

```json
{
  "blacklist": ["com.apple.dock", "com.apple.systemuiserver", "com.apple.loginwindow", "WindowServer"],
  "debugLogging": false,
  "pollInterval": 0.2
}
```

Blacklist entries match by bundleIdentifier (preferred — stable across locales) or by app name (fallback).

## License

MIT
