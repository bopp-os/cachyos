# bopp-tray — BoppOS Update Notifier

A lightweight system-tray update notifier for BoppOS's `bootc`-based atomic
image system.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  SYSTEM (root)                                                  │
│                                                                 │
│  boppos-update-monitor.timer  (every hour + on boot)           │
│          │                                                      │
│          ▼                                                      │
│  boppos-update-monitor.service                                  │
│          │                                                      │
│          ▼                                                      │
│  /usr/lib/boppos/update-check.sh                                │
│    1. bootc status --format=json   → parse current/staged       │
│    2. bootc upgrade --check        → fetch upstream if needed   │
│    3. bopp-diff --staged           → package diff text          │
│    4. write /run/boppos/update-status.json  (mode 0644)         │
│    5. pkill -SIGUSR1 bopp-tray                                  │
└─────────────────────────────────────────────────────────────────┘
                              │ SIGUSR1 / file read
┌─────────────────────────────▼───────────────────────────────────┐
│  USER SESSION                                                   │
│                                                                 │
│  bopp-tray  (Python, pystray)                                   │
│    • reads /run/boppos/update-status.json                       │
│    • shows blue icon (idle) or orange icon (update available)   │
│    • sends notify-send desktop notification (once per digest)   │
│    • right-click menu:                                          │
│        – Check now            → pkexec systemctl start ...      │
│        – View changes         → opens bopp-diff in terminal     │
│        – Apply update & reboot → opens boppos-update in term    │
│        – Last checked: HH:MM  (disabled label)                  │
│        – Quit                                                   │
└─────────────────────────────────────────────────────────────────┘
```

## Files

| Path | Purpose |
|------|---------|
| `usr/bin/bopp-tray` | User-space tray app (Python) |
| `usr/lib/boppos/update-check.sh` | Privileged check script |
| `usr/lib/systemd/system/boppos-update-monitor.service` | System oneshot |
| `usr/lib/systemd/system/boppos-update-monitor.timer` | Hourly trigger |
| `usr/lib/systemd/user/bopp-tray.service` | User session service |
| `etc/xdg/autostart/bopp-tray.desktop` | XDG autostart fallback |
| `usr/share/polkit-1/rules.d/50-boppos-update-monitor.rules` | Passwordless "Check now" |

## Integration with bopp-diff

`update-check.sh` calls `bopp-diff --staged` if the binary exists on PATH.
The `bopp-diff` script should accept a `--staged` flag and write a human-readable
package diff to stdout comparing the currently booted image against the staged one.
If your current `bopp-diff` doesn't support `--staged`, you can either:

- Add the flag to bopp-diff, or
- Have update-check.sh invoke it differently and adjust the call in update-check.sh.

The diff text is embedded in the JSON status file and surfaced via the
"View changes" menu item (written to a temp file and opened in `less`).

## Adding to the image

See `Containerfile.bopp-tray.snippet` for the exact lines to add to
`Containerfile.base`.  In short:

1. Drop all files under `files/base/` as shown.
2. Add the snippet's `RUN pacman` + `RUN systemctl enable` lines.
3. The existing `COPY files/base/usr/bin /usr/bin` already picks up `bopp-tray`.

## Autostart

The tray app starts via **two** mechanisms so it works on all supported DEs:

- **`bopp-tray.service`** (systemd user unit) — KDE Plasma and GNOME both honour
  `graphical-session.target`.
- **`bopp-tray.desktop`** (XDG autostart) — fallback for Niri or any DE that
  doesn't use systemd user sessions.

To avoid double-starting, `bopp-tray` uses `fcntl` file locking; a second
instance will exit immediately.

## Manual testing

```bash
# Trigger an immediate check
sudo systemctl start boppos-update-monitor.service

# Watch the status file
watch -n1 cat /run/boppos/update-status.json

# Run the tray app in the foreground
bopp-tray
```
