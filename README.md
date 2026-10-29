[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/M4M81TUBKF)

# CachyOS BoppOS 🚀

**A high-performance, desktop-focused atomic (`bootc`) Linux image based on CachyOS.**

CachyOS BoppOS is a custom-built OS designed for high-end desktop gaming and development. It's a fork of `cachyos-deckify-bootc`, transformed from a handheld-oriented system into a powerful, desktop-first experience.

This is all very experimental. So use at your own risk.

---

## Key Features

- **High-Performance Base**: Built on [CachyOS](https://cachyos.org/), an Arch-based distribution with performance-tuned kernels and repositories.
- **Atomic & Immutable**: Uses [bootc](https://bootc-dev.github.io/) for an atomic, image-based system that offers incredible stability and easy rollbacks.
- **Desktop Choice**: Choose your preferred flavor: KDE Plasma, GNOME, Cinnamon, or the Niri Wayland compositor.
- **Modern Hardware Support**: Includes build-time support for `znver4` CPU optimizations for AMD Ryzen 7000 series processors.
- **Gaming Ready**: Comes with a suite of pre-installed gaming software and utilities:
  - `cachyos-gaming-applications`, `proton-cachyos`, `wine-cachyos`
  - `sunshine`, `mangohud`, `goverlay`, `lact`
  - `faugus-launcher`, `umu-launcher`, `winboat`
- **Developer Focused**: Includes essential development environments and tools out of the box:
  - Homebrew (`brew`) support integrated into the base image
  - `distrobox` container-native environment (run any distro's toolchain natively)
  - `docker`, `docker-compose`, and `podman`
  - `python-pip` and `python-pipx` for user-space app installations
- **Laptop Hardware Compatibility**: Pre-installed compatibility and management tools for ASUS (`asusctl`), GPU switching (`cardwire`; the Cinnamon flavor uses `switcheroo-control`), Framework and generic laptops (`power-profiles-daemon`, `iio-sensor-proxy`, `bolt`, `fprintd`). Systemd services are kept disabled by default to eliminate background overhead on non-target hardware.
- **Seamless Setup & Migration**: Features custom scripts to transition safely from other atomic distributions (`bopp-migrate`).
- **Hardware Encryption Utility**: Includes `bopp-tpm-refresh` to automatically re-enroll LUKS TPM2 encryption keys after system updates or migrations.
- **Enhanced Shell**: A pre-configured shell environment with `starship`, `zoxide`, and `eza` for a modern terminal experience.

## Custom Enhancements

- **Desktop First:** Stripped away Steam Deck/handheld-specific UI elements and scaling tweaks in favor of standard desktop environments (with support for KDE Plasma, GNOME, Cinnamon, and Niri).
- **Developer Ready:** Pre-installed essentials like Distrobox, Homebrew (`brew`), Docker, and Python (with full support for container-native development workloads).
- **BoppOS Tools:** We have created a suite of custom administration utilities, available in the [boppos-tools repository](https://github.com/bopp-os/boppos-tools).

⚠️ **WARNING: HIGHLY EXPERIMENTAL AND POTENTIALLY DESTRUCTIVE** ⚠️
Some of these tools (specifically `bopp-migrate`) manipulate core system and user configurations. **Do NOT run them unless you fully understand what they do.** They are largely untested and could result in a broken system or data loss. Always ensure you have a separate, verified backup of your data before running migration commands.

Important commands included in `boppos-tools`:
- `boppos-update`: A comprehensive update script that seamlessly updates your OS (`bootc`), firmware, Flatpaks, Homebrew, Distroboxes, and Litterboxes.
- `bopp-tray`: A background tray application that checks for new image updates periodically.
- `boppos-deck` (`org.boppos.Deck`): A gamepad-first settings app for updates, kernel arguments, Flatpaks, Steam shortcuts and Decky Loader. Works with a controller in Steam Gaming Mode and with mouse and keyboard in Desktop Mode. It is also the first-run app (`boppos-deck --first-run`), see [First boot](#first-boot-and-image-defaults).
- `bopp-system`: The command-line backend for updates and deployments in `boppos-deck`: status, check, upgrade, rollback, pin, image switching and a support report (`--json` for scripts).
- `bopp-decky`: Shows the status of, installs or uninstalls Decky Loader.
- `bopp-steam-shortcut`: Adds or removes non-Steam shortcuts (Flatpak apps, BoppOS tools) in the Steam library.
- `bopp-diff`: Analyzes the current running system against staged or upstream `bootc` images to provide a clear package diff.
- `bopp-kargs`: A utility to manage Boot Loader Specification (BLS) kernel arguments for atomic deployments. The image only turns on `rd.luks.options=tpm2-device=auto` and `splash` by default; the other tuning arguments are opt-in presets (see `docs/first-run-and-autologin.md`).
- `bopp-tpm-refresh`: Re-enroll LUKS/TPM2 decryption keys after system updates.
- `bopp-dev-setup`: Provisions a container-native development environment in a CachyOS-based Distrobox container, optimized for your CPU's microarchitecture.
- `bopp-migrate`: Transition your `$HOME` and `/etc` configurations from Fedora-based atomic distributions to this Arch-based BoppOS image.
- `install-optional-flatpaks`: An interactive script to easily fetch, customize, and install a curated list of essential Flatpak applications.

## First boot and image defaults

What a freshly installed image does, and what it deliberately leaves off:

- **First run:** `boppos-tools` starts `boppos-deck --first-run`. On a system with no real account (uid 1000 to 59999 with a login shell), `boppos-oobe.service` runs the account setup before the login screen. It is enabled in the image and needs `gamescope`, which the image installs. After that, the welcome tour starts from `/etc/xdg/autostart/bopp-welcome.desktop` until it is finished. The BoppOS installer writes the marker `/var/lib/boppos/first-run`. `/var/lib/boppos` is created at every boot by tmpfiles. This needs boppos-tools 1.3.x plus the `claude/first-run-unified` branch, which is not released yet.
- **sudo:** members of `wheel` can use `sudo` (`/etc/sudoers.d/10-wheel`). The installer puts the first user in `wheel`.
- **Cloudflare WARP is optional:** the package is installed, but `warp-svc` and `warp-taskbar` are disabled. Turn it on with `sudo systemctl enable --now warp-svc` and `systemctl --user enable --now warp-taskbar`.
- **Boot splash:** the BoppOS Plymouth theme (two-step, with the firmware logo), set in `Containerfile.base` before dracut builds the initramfs.
- **Launcher icon:** the Plasma application launcher uses `boppos-icon`.
- **Boot menu tools:** `grub` is installed for `grub-mkconfig` and the `15_ostree` script on installs that use grub.
- **Autologin / "start in Gaming Mode or Desktop":** not available yet, because no flavor ships a Gaming Mode session. Per-flavor details and what is unverified: [docs/first-run-and-autologin.md](docs/first-run-and-autologin.md).

## Installation & Switching

This image is designed to be managed by `bootc`. The recommended and easiest way to install BoppOS is to switch an existing `bootc`-based OS directly to it without losing your data. Alternatively, you can perform a fresh installation on a new system.

### 1. Switching from an Existing bootc OS (Recommended)

If you are already running a `bootc`-based system (e.g., Bazzite, Bluefin, or Fedora Atomic desktops with bootc), you can switch to BoppOS directly without needing to reformat or reinstall. This is one of the major advantages of `bootc`.

To switch, run the following command, pointing to the BoppOS image in your registry:

```bash
sudo bootc switch ghcr.io/bopp-os/cachyos-plasma:latest
```

Your system will download the new image and stage it for the next boot.

**Note on Signature Verification**: For a secure transition, you may need to configure your system to trust the signature of the new image. The `Containerfile` includes a `cosign.pub` key and `policy.json`, which you may need to adapt for your registry and signing setup.

### 2. Fresh Installation

After building the container image, you can:

1.  Push it to a container registry (like `ghcr.io`, `quay.io`, or a local registry).
2.  Use `bootc install` from a live environment to install CachyOS BoppOS to a target disk.

For detailed installation instructions, refer to the official bootc documentation.

A typical installation command would look like this:

```bash
# Example:
bootc install to-disk --image ghcr.io/bopp-os/cachyos-plasma:latest /dev/sdX
```

## Build Instructions

CachyOS BoppOS uses `just` as a command runner to simplify the build process. Ensure you have `just` and `podman` installed.

The OS is built using a multi-image architecture. You must first build the `base` image, and then build your preferred desktop environment flavor (`plasma`, `gnome`, `niri`, or `cinnamon`) on top of it.

**You cannot create an image for an architecture your build system doesn't support!**<br\>

### x86-64-v3 Build (v3 Default)

This build is compatible with most modern x86-64 hardware and is suitable for sharing or for use in CI/CD environments.

```bash
# 1. Construct the fastest-mirror list
just build-mirrorlist v3

# 2. Build the base image
just build v3 base

# 3. Build your preferred flavor (e.g., plasma, gnome, niri, cinnamon)
just build v3 plasma
```

### x86-64-v4 Build (v4)

This enables optimizations for a wide range of modern CPUs (e.g., Intel Haswell and newer, AMD Excavator and newer) that support the x86-64-v4 microarchitecture level.

```bash
# 1. Construct the fastest-mirror list
just build-mirrorlist v4

# 2. Build the base image
just build v4 base

# 3. Build your preferred flavor (e.g., plasma, gnome, niri, cinnamon)
just build v4 plasma
```

### Zen4/Zen5 Build (znver4)

If you are building on and for a system with an AMD Ryzen 7000 series CPU (or newer), you can enable native `znver4` optimizations for maximum performance.

```bash
# 1. Construct the fastest-mirror list
just build-mirrorlist znver4

# 2. Build the base image
just build znver4 base

# 3. Build your preferred flavor (e.g., plasma, gnome, niri, cinnamon)
just build znver4 plasma
```

### Switching to a Local Build

If you are building the image locally and want to apply it to your current system without pushing to a registry first, you can use the `just switch` command. This transfers the locally built container from your user environment to the root environment and tells `bootc` to switch to it via local storage.

```bash
# 1. Construct the fastest-mirror list
just build-mirrorlist

# 2. Build the image
just build

# 3. Switch to the local v3 build
just switch

# (Optional) Switch to a specific architecture tag instead (requires having built them separately already):
just switch v4
just switch znver4
```

## Acknowledgements

This project was made possible by the excellent work of the CachyOS team and the creators of the original [cachyos-deckify-bootc](https://github.com/lumaeris/cachyos-deckify-bootc) repository from which this was forked. It also stands on the shoulders of the [Bootcrew](https://github.com/bootcrew) and [bootc](https://github.com/containers/bootc) projects.
