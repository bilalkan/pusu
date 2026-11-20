# Changelog

## 1.0.1 — 2026-11-20

Security hardening after an independent audit (no critical or high findings), plus small fixes.

- The privileged helper is now installed without any root-executed file on disk: the install script is passed directly to the admin prompt, the LaunchDaemon plist is generated inside it, and the helper binary is copied to a root-only staging folder and checked against a SHA-256 pinned at build time before it's installed.
- The helper only accepts requests from root and the user at the console, logs only state changes, caps its log size, and handles shutdown and requests on one queue, so stopping it can't race a request.
- Lid mode never opens a password prompt when triggered from the command line or another app; it needs the helper for that.
- `pusu://` links are limited to `on`, `off`, `toggle`, `wake` and `settings`, with sessions of at most 8 hours.
- Out-of-range durations from other apps are rejected instead of crashing Pusu.
- Turning lid mode off no longer reports success if the helper is installed but not answering.
- Helper connection timeouts under one second now work as intended.
- Homebrew uninstall restores `SleepDisabled` even if the helper isn't running.
- The login item no longer points at a copy of Pusu opened from a disk image or Downloads.

## 1.0.0 — 2026-11-20

First public release.

- Keep the system (and optionally the display) awake, on a timer or indefinitely.
- Battery guard, lid mode with an optional privileged helper, and a remote access (VNC) mode that turns the display off and can lock the session.
- Settings window with Session, History, System and Settings tabs; crash-safe session history.
- `pusu` command line tool and `pusu://` URL scheme.
- Turkish and English interface, following the macOS language or chosen in Settings.
- Universal build for Apple silicon and Intel, macOS 13 or later.
