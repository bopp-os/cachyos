# First run and autologin, per flavor

Findings from the published `v3` flavor images (plasma: the `v3-test` build, which has the same login stack) and
their file tables. Nothing here was run: no flavor was booted. Session names are the `.desktop` files that exist
in `/usr/share/wayland-sessions` and `/usr/share/xsessions` of each image.

## Where first-run starts

boppos-tools (branch `claude/first-run-unified`, not merged) starts `boppos-deck --first-run` from two places; the
image adds no trigger of its own:

- `/etc/xdg/autostart/bopp-welcome.desktop`, at every sign-in (the app exits at once when nothing is pending).
- `boppos-oobe.service`, before the display manager, only while no real account exists. The package ships no
  preset for it, so `Containerfile.base` runs `systemctl enable boppos-oobe.service`. It needs the `boppos-oobe`
  account (the package's sysusers entry; present in the image) and gamescope (`base.yaml`).

**Deck (Game Mode).** XDG autostart never runs in the gamescope session. The first boot is Steam's own, as on
SteamOS, ChimeraOS and Bazzite: the installer preloads the Steam client and copies the Wi-Fi connection, Steam's
setup (Wi-Fi, sign-in) runs first, and BoppOS is a shortcut in the Steam library; started from there while the
first-run marker exists, boppos-deck opens the welcome tour. A window of ours before Steam fought gamescope's Steam
mode on a Legion Go (invisible, frozen frames, no gamepad or touch). Nothing opens the tour automatically: an
attempt to restart Steam after the sign-in and launch the shortcut with `steam://rungameid` ended on Steam offering
to stream BoppOS from another PC (the shortcut id is the same on every BoppOS machine), so it was removed.

- While Steam starts, updates or unpacks itself, its update screen shows
  `/usr/share/plymouth/themes/steamos/steamos.png` (gamescope-session-cachyos sets `STEAM_UPDATEUI_PNG_BACKGROUND`
  to it on non-Valve hardware; no package ships it). The image ships a BoppOS one ("Getting Steam ready"), rendered
  from `files/deck/steam-update-background.svg`, so the first start is not a black screen.
- `steam-launcher.service.d/10-boppos.conf` runs `/usr/libexec/boppos/deck-before-steam` before every Steam
  start (Steam is closed then, the only time its library can be written): when `bopp-steam-shortcut apps` shows
  the BoppOS shortcut missing, `bopp-steam-shortcut add --force` (every time it is missing: it is the only way to
  BoppOS in Game Mode), and `apply-pending` (queued library changes). On the first boot
  there is no Steam user yet when Steam starts, so the shortcut appears from the next Steam start (a reboot, or
  leaving and re-entering Game Mode).
- Fallback: `boppos-deck-first-boot.service`, which `gamescope-session.service` waits for (drop-in
  `gamescope-session.service.d/10-boppos-first-boot.conf`), runs `/usr/libexec/boppos/deck-first-boot`. Only when
  Steam has no client (no `steamui.so` in the home, and the image's `/usr/lib/steam` bootstrap is not the whole client as `steam-jupiter-stable`'s is) and there is no network, it opens `boppos-deck --welcome`
  with `BOPPOS_FIRST_BOOT_MISSING="steam network"` as the only app in a gamescope of its own (`--backend drm`, not
  Steam mode, which only shows windows Steam picks), then the Plasma network settings (`kcmshell6
  kcm_networkmanagement`) if still offline. Offline with Steam installed is not a problem: Steam has an offline
  mode.

`/var/lib/boppos` (root:root 0755) is made at boot by `files/base/usr/lib/tmpfiles.d/10-boppos-state.conf`. The
marker `first-run` is written by the installer and removed by the root `oobe-helper`. Nothing in the image
references `/var/lib/boppos/oobe-done` (gone in the new design).

`/usr/share/boppos/start-in.conf` ships only in the niri flavor (SDDM is the only implemented display manager).
Its `gaming-session` is empty because no Gaming Mode session exists, so the Start-in step stays hidden.

## Sessions that exist

| Flavor   | Display manager        | Sessions in the image                                                         |
|----------|------------------------|-------------------------------------------------------------------------------|
| plasma   | plasmalogin            | wayland: `plasma.desktop`                                                      |
| gnome    | gdm                    | wayland: `gnome.desktop`                                                       |
| niri     | sddm                   | wayland: `niri.desktop`, `weston.desktop`                                      |
| cinnamon | greetd + regreet (cage)| wayland: `cinnamon-wayland.desktop`; x11: `cinnamon.desktop`, `cinnamon2d.desktop` |
| deck     | plasmalogin            | wayland: `gamescope-session.desktop` (default), `plasma.desktop`               |

**Only the deck flavor has a Gaming Mode session.** It ships `gamescope-session-cachyos`, whose
`/usr/share/wayland-sessions/gamescope-session.desktop` is the session, and `steamos-session-select` switches between
it and Plasma (`steam-set-session` writes `/etc/plasmalogin.conf.d/zz-steamos-autologin.conf`). The image's
`boppos-deck-autologin.service` runs before the display manager on every boot and writes the autologin user
(`/etc/plasmalogin.conf.d/00-boppos-autologin.conf`, the account with UID 1000, falling back to the first `wheel`
member, `Relogin=true`, and the `Session=` copied from `zz-steamos-autologin.conf`) and points `/var/home/deck` at
that home, so Decky plugins with hard-coded `/home/deck` paths work. plasmalogin does not read
`zz-steamos-autologin.conf` here (Legion Go: with a `Session=` in our file it used ours, so "Switch to Desktop" came
back to Game Mode; without one it logged `Unable to find autologin session entry ""`). So
`boppos-deck-session-sync.path` reruns the script whenever `steam-set-session` rewrites that file, and the choice is
copied into ours before plasmalogin logs in again. When that file is missing it writes it for Game Mode, and it
drops one naming a session the image lacks. With no
account yet (first boot before OOBE) it does nothing. The desktop flavors (plasma, gnome, niri, cinnamon) have no
Gaming Mode session: `start-in.conf` leaves `gaming-session` empty there.

**Deck desktop (Plasma): CachyOS Handheld's.** The image installs `cachyos-handheld` (CachyOS Handheld's own
package, with `steam-jupiter-stable` in place of `steam`, which it conflicts with; same Steam bootstrap tarball the
installer's preload uses). It brings the handheld KWin/input/power/screen-lock defaults, the Vapor look, the Plasma
on-screen keyboard, `/etc/xdg/autostart/steam.desktop` (`steam -silent -steamdeck`: Steam's desktop controller layout
is what makes the controls work as a mouse and keyboard), `XwaylandEisNoPrompt=true` in `kwinrc` (Steam may control
input without Plasma's "allow control" prompt), and Legion Go / ROG Ally speaker tuning.

Its install script sets things up for the user at install time; an image is built before any user exists, so:
- `/etc/plasmalogin.conf.d/steam-deckify.conf` (autologin with an empty/`deck` user and its own `Session=`) is
  deleted in `Containerfile.deck`; `deck-autologin` writes the real user and session.
- `/etc/handheld-first-boot` is deleted. Only CachyOS's `holo-update` reads it (the first time Steam checks for a
  system update it removes the file and restarts `graphical.target`); the image replaces that `holo-update` with
  BoppOS's, so it would never be read, and removing it means it can never fire.
- `DECKY_USER` / `DECKY_USER_HOME` in `/etc/environment.d/handheld.conf` are written every boot by `deck-autologin`.
- "Return to Gaming Mode": the package's entry runs `steamosctl switch-to-game-mode`, and steamos-manager writes
  SDDM paths (`/etc/sddm.conf.d`, `zzt-steamos-temp-login.conf`), unproven with plasmalogin. The image replaces
  `/usr/share/applications/steamos-gamemode.desktop` and `/etc/skel/Desktop/steamos-gamemode.desktop` with one that
  runs `steamos-session-select gamescope` (followed by `boppos-deck-session-sync.path`), keeping its
  `steamdeck-gaming-return` icon. `deck-desktop-setup` (XDG autostart, once per account) copies it to `~/Desktop`
  for accounts made before the image shipped it.
- KDE wallet: after autologin there is no login password to unlock one with, so the first app storing a secret
  (Bazaar on a Legion Go) opened KWallet's setup wizard ("no keys suitable for encryption"). `deck-desktop-setup`
  gives an account without `~/.local/share/kwalletd/kdewallet.kwl` SteamOS's default wallet (empty password, from
  Valve's `steamdeck-kde-presets`, GPL-2.0, in `/usr/share/boppos/kwalletd`) and sets `First Use=false`, as SteamOS's
  `holo-setup-kwallet` does. Trade-off, same as SteamOS: secrets in it are not protected by a password.

## Turning autologin on (user + session), per flavor

| Flavor   | File | Content | Verified how |
|----------|------|---------|--------------|
| plasma   | `/etc/plasmalogin.conf`, or a drop-in in `/etc/plasmalogin.conf.d/` (also read: `/usr/lib/plasmalogin/plasmalogin.conf.d/`) | `[Autologin]` with `User=`, `Session=`, `Relogin=` | Paths and key names found in the `plasmalogin` and `kcmplasmalogin_authhelper` binaries. The image ships no config file. **Not verified:** whether `Session=` takes `plasma` or `plasma.desktop` (the daemon logs "Unable to find autologin session entry" when it fails). |
| gnome    | `/etc/gdm/custom.conf` | `[daemon]` with `AutomaticLoginEnable=True` and `AutomaticLogin=USER` | Keys found in the `gdm` binary; the shipped `custom.conf` has an empty `[daemon]`. GDM has no session key there: the session comes from AccountsService (`/var/lib/AccountsService/users/USER`, `Session=gnome`), **not verified** in this image. |
| niri     | `/etc/sddm.conf.d/NAME.conf` | `[Autologin]` with `User=USER` and `Session=niri` | The image's `/usr/lib/sddm/sddm.conf.d/default.conf` has the `[Autologin]` section (`Relogin`, `Session`, `User`) with all values empty. SDDM names sessions by their desktop file; `niri.desktop` exists. Note `etc/sddm.conf.d/theme.conf` already exists, so use another file name. |
| cinnamon | `/etc/greetd/config.toml` | add `[initial_session]` with `command = "cinnamon-session-cinnamon"` and `user = "USER"` (X11 `cinnamon.desktop` runs `cinnamon-session-cinnamon`; the Wayland entry runs `cinnamon-session-cinnamon --wayland`) | Section and key names found in the `greetd` binary; the shipped config has only `[terminal]` and `[default_session]` (cage + regreet as user `greeter`). greetd starts a command, not a session name, so the Exec lines come from the `.desktop` files. |

Not covered: regreet's own "remember last session" state, `Relogin` after logout, and what happens when the
user later disables autologin.

## Account basics

- `wheel` exists in the image (`/etc/group`: `wheel:x:998:`); `files/base/etc/sudoers.d/10-wheel` lets it use
  sudo and the build sets mode 0440.
- The shadow fix: with `SOURCE_DATE_EPOCH=0`, 22 build-time accounts (including `plasmalogin`, `boppos-oobe`,
  `polkitd`, `avahi`) had lastchg `0` in the `v3-test` image. `bootc-cleanup.sh` now empties that field for locked
  accounts and fails the build if any is left. It runs last in the base and in every flavor.
- `SOURCE_DATE_EPOCH=0` is a build `ARG`, not an `ENV`: the RUN steps keep reproducible timestamps, but the value
  never reaches the image's environment. The accounts are created by pacman hooks (`systemd-sysusers`), so unsetting
  it for them alone is not possible without losing reproducible output for the whole install; the cleanup above stays.

## Open items (as of 2026-10-29)

- **boppos-tools first run is not released.** `boppos-deck --first-run` and the `bopp-welcome.desktop` /
  `boppos-oobe.service` behaviour described above are on the boppos-tools branch `claude/first-run-unified`.
  The image already enables `boppos-oobe.service`; on a bare `bootc install` with no account it starts gamescope
  before the login screen and has nothing to run until that branch ships.
- **Kernel arguments.** `files/base/usr/lib/bootc/kargs.d/90-boppos-optimizations.toml` only enables
  `rd.luks.options=tpm2-device=auto` and `splash`. The tuning kargs removed from it are kept as comments in that
  file until boppos-tools presets (`/usr/lib/bopp-kargs.d/`) replace them. Nothing in the image copies presets into
  `/usr/lib/bootc/kargs.d/`.
- **`sysroot.bootloader`.** `bopp-kargs` needs the target's `/ostree/repo/config` to have
  `sysroot.bootloader=grub2` (or an `auto` that finds grub). The image cannot set it: the ostree repo is created
  at install time, and bootc's install code runs `ostree config set sysroot.bootloader` there (the value it sets was not read). The
  installer or `bopp-kargs` has to set it; the image ships `grub` so `grub-mkconfig` exists.
- **Gaming Mode session.** None of the four flavors installs a Gaming Mode session entry, so `start-in.conf`
  (niri only) leaves `gaming-session` empty and the Start-in step stays hidden.
- **Not verified by a boot:** plasmalogin's `Session=` value format, GDM's AccountsService session, the first-run
  flow, and the image's `bootc` ostree bootloader setting.
