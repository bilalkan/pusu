# Changelog

## 1.0.2 — 2026-11-20

- `brew upgrade` keeps the privileged helper: no password prompt during upgrades and no need to reinstall the helper afterwards. (Upgrading from 1.0.1 still removes it once, because Homebrew uses the old version's uninstall steps.)
- When Pusu is uninstalled or moved — with Homebrew, by dragging it to the Trash, or otherwise — the helper restores `SleepDisabled` and removes itself once the app has been gone for about 15 minutes. This needs the updated helper (Settings › System › Update Helper…). `brew uninstall --zap` removes it right away, restoring `SleepDisabled` even if the helper isn't running.
- The helper can only be installed for a copy of Pusu in the Applications folder; Pusu offers to update it if the app was moved.
- If the sleep setting is restored outside Pusu while lid mode is on, Pusu turns lid mode off in its menu and tells you.
- An outdated helper can still turn lid mode off (also when quitting); messages no longer call it "not installed".
- `pusu lid on|off` prints a clear error and exits non-zero when it can't proceed without a password prompt.
- Out-of-range durations sent by other apps are rejected instead of falling back to the default.
- `pusu version` and the CLI's language now match the installed app when run through the `pusu` link.
- Turning lid mode off from the menu no longer waits for slow helper retries on the main thread.

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
