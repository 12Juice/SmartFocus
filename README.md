# SmartFocus

A macOS menu bar app that restores keyboard focus when the frontmost window closes.

macOS sometimes drops focus to the Desktop/Finder after you close a window. SmartFocus detects that focus vacuum and activates the topmost remaining usable window instead.

## Features

- **Focus restoration** on window close (Cmd+W), with minimal interference: if macOS already falls back to a usable app, SmartFocus accepts it and does nothing
- **Stays on your Space**: closing a window whose app still has windows on another Space would normally yank macOS there — SmartFocus pulls focus back to the next window on the Space where you closed it (disable via `stayOnSpaceOnClose: false`; a deliberate manual Space switch within 0.8s of a close may be pulled back once)
- **Event-driven, no polling**: a WindowServer notify-proc tap (SkyLight private API — the AltTab/yabai mechanism) delivers window create/destroy/order/focus and Space-switch events the instant they happen; `NSWorkspace` notifications remain as a redundant trigger, and a 5s fallback timer only self-heals (missed events, permission watchdog, subscription re-sync)
- **Hot-reloaded config** at `~/.smartfocus/config.json` (app blacklist, debug logging), survives atomic saves
- Built-in **log console** with debug/error levels (errors only, unless debug logging is on)
- **Launch at login** (macOS 13+ via `SMAppService`)
- **No permissions needed**: window matching runs off pids (TCC only strips owner *names* from the window list, not the list itself), so there is no Screen Recording prompt and nothing to re-grant after upgrades

## Build & Package

```bash
./build.sh          # produces build/SmartFocus.app (ad-hoc signed)
./package.sh        # additionally produces build/SmartFocus-<version>.dmg
                    # (drag-to-install layout with an /Applications symlink)
```

Requires Xcode Command Line Tools.

## Install

Open the DMG and drag SmartFocus to Applications — or directly:

```bash
cp -R build/SmartFocus.app /Applications/
```

Note: with ad-hoc signing, re-building invalidates the registered login item — re-toggle it after upgrading, or sign with a stable local certificate. The DMG is not notarized (no Developer ID certificate); on other machines Gatekeeper will challenge it — right-click → Open, then confirm.

## Config

`~/.smartfocus/config.json`:

```json
{
  "blacklist": ["com.apple.dock", "com.apple.systemuiserver", "com.apple.loginwindow", "WindowServer"],
  "debugLogging": false,
  "stayOnSpaceOnClose": true
}
```

Blacklist entries match by bundleIdentifier (preferred — stable across locales) or by app name (fallback). A legacy `pollInterval` key is still accepted but ignored — detection is event-driven.

## License

MIT
