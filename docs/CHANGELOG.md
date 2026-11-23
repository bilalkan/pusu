# Changelog

## 1.0.6 — 2026-11-23

- **Tern's Screen tab wakes the display.** A desktop Tern window with a terminal tab keeps one connection open for hours, and opening the Screen tab reuses it, so Pusu never saw a new connection: the display stayed asleep and Tern said "This Mac has no display to share". In remote access mode Pusu now also notices when Tern asks for the screen and wakes the display dark, the same way as for a new connection. It follows macOS's own log for this with a narrow filter while the mode is on; no admin rights, nothing is sent anywhere.
- **Warning when the helper disappears.** If the privileged helper is removed outside Pusu (for example by an old Homebrew cask during an upgrade), Pusu records it in the event log and shows one notification, so lid mode doesn't fail later with an unexpected password prompt. Installing or removing the helper from Pusu itself never warns.
- The display assertion is now named "Pusu keeps the display on" in `pmset -g assertions`, separate from the system one.

## 1.0.5 — 2026-11-21

Remote access mode, rebuilt after testing with Screen Sharing and with Tern from a phone.

- **Display off until someone connects.** The session locks and the display sleeps (about 0.7 W on an M2 MacBook Air, versus about 4.7 W at normal brightness). Apple Screen Sharing wakes the display itself.
- **Tern support.** When Tern connects, the display wakes but stays dark: brightness, keyboard backlight and the picture on the built-in panel are turned down, while the remote side sees the lock screen normally (about 2 W). If nobody looks at the screen within 30 seconds (a terminal-only connection), or when Tern disconnects, the Mac locks and the display sleeps again. Pusu reads Tern's own log file for this; nothing is sent anywhere.
- **Lid closed.** With lid mode on, closing the lid switches to a virtual display, so remote connections still see the lock screen and can unlock it (about 1 W). With lid mode on, the display is kept dark instead of asleep so the lock screen moves over when the lid closes.
- **Someone at the Mac.** Touching the Mac's own keyboard or trackpad — even on the lock screen — or opening the lid ends remote access mode and brings the display back. Input from Tern or Screen Sharing doesn't count.
- Display brightness and the keyboard backlight return to their levels from before the mode; after an unexpected quit, at the next launch. The keyboard backlight is only dimmed temporarily, so its setting in Control Center is never changed.
- New option for other remote access apps: "Never sleep the display" keeps it on but dark.
- **Event log.** `pusu log` shows what happened in the last three days (sessions, remote access, display sleep and wake, screen lock, lid). Kept only on this Mac; the last events are also in the diagnostics.
- Commands from the `pusu` command line are confirmed by the app and resent if needed, so a command sent right after launch is no longer lost.
- Remote access can be started without Screen Sharing when Tern is installed.

## 1.0.4 — 2026-11-20

- Optional update check. On first launch Pusu asks whether to check automatically once a day or only when you ask; "Check for Updates…" in the menu works either way. A new version shows up in the menu with one notification, with the `brew upgrade` command for Homebrew installs. The check only reads GitHub's public latest-release address — no cookies, identifiers or usage data.

## 1.0.3 — 2026-11-20

- Click the menu bar icon to turn Pusu on or off; right-click (or Control-click) opens the menu. You can switch back to "click opens the menu" in Settings. The icon's tooltip and the welcome message explain it, and VoiceOver offers a "Show menu" action.

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
