# Changelog

## 1.0.1 — 2026-11-20

Security hardening after two independent reviews (no critical or high findings), plus small fixes.

- The privileged helper is installed without any root-executed file on disk: the install script goes straight to the admin prompt, the LaunchDaemon plist is generated inside it, and the helper is copied to a root-only folder and checked against a SHA-256 pinned at build time. Installation is refused if the checksum is missing.
- `scripts/uninstall.sh` uses the same approach, and also restores `SleepDisabled` for lid mode used without the helper.
- Commands from outside the app (the `pusu` command line, other apps, `pusu://` links) never open a password prompt.
- `pusu://` links are limited to `on`, `off`, `toggle`, `wake` and `settings`; sessions they start last at most 8 hours, and invalid durations are rejected.
- Out-of-range durations from other apps are rejected instead of crashing Pusu.
- The helper only changes `SleepDisabled` after it has saved the original value, keeps that record if a restore fails, restores it when it's stopped, handles shutdown and requests in order, logs only state changes, and keeps its log small and root-only.
- Lid mode is only turned on through an up-to-date helper; an older helper can still turn it off.
- Turning lid mode off works correctly when sleep was already disabled before Pusu, and no longer reports success if the helper isn't answering.
- Helper connection timeouts under one second now work as intended, and a closed helper connection can't terminate the app.
- Homebrew uninstall restores `SleepDisabled` even if the helper isn't running.
- "Open at login" refuses to point at a copy of Pusu running from a disk image or Downloads.

## 1.0.0 — 2026-11-20

First public release.

- Keep the system (and optionally the display) awake, on a timer or indefinitely.
- Battery guard, lid mode with an optional privileged helper, and a remote access (VNC) mode that turns the display off and can lock the session.
- Settings window with Session, History, System and Settings tabs; crash-safe session history.
- `pusu` command line tool and `pusu://` URL scheme.
- Turkish and English interface, following the macOS language or chosen in Settings.
- Universal build for Apple silicon and Intel, macOS 13 or later.
