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

**No flavor has a Gaming Mode session.** There is no `gamescope-session-steam.desktop` (or any gamescope or steam
entry) in any of the four images. Only `gamescope-session-git` (the generic `gamescope-session-plus`, which has no
session entry of its own) is installed. `oobe_helper.py` in boppos-tools 1.3.1 maps "gaming" to
`gamescope-session-steam` and marks it UNVERIFIED: it does not exist here. Something has to ship the session
entry before "start in Gaming Mode" can be implemented (a package such as `gamescope-session-steam-git`, or an
entry we write). That is a decision for the boppos-tools session.

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
