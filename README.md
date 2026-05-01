[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/M4M81TUBKF)

# CachyOS BoppOS 🚀

**A high-performance, desktop-focused atomic (`bootc`) Linux image based on CachyOS.**

CachyOS BoppOS is a custom-built OS designed for high-end desktop gaming and development. It's a fork of `cachyos-deckify-bootc`, transformed from a handheld-oriented system into a powerful, desktop-first experience.

This is all very experimental. So use at your own risk.

---

## Key Features

- **High-Performance Base**: Built on [CachyOS](https://cachyos.org/), an Arch-based distribution with performance-tuned kernels and repositories.
- **Atomic & Immutable**: Uses [bootc](https://bootc-dev.github.io/) for an atomic, image-based system that offers incredible stability and easy rollbacks.
- **Desktop Choice**: Choose your preferred flavor: KDE Plasma, GNOME, or the Niri Wayland compositor.
- **Modern Hardware Support**: Includes build-time support for `znver4` CPU optimizations for AMD Ryzen 7000 series processors.
- **Gaming Ready**: Comes with a suite of pre-installed gaming software and utilities:
  - `cachyos-gaming-applications`, `proton-cachyos`, `wine-cachyos`
  - `sunshine`, `mangohud`, `goverlay`, `lact`
  - `faugus-launcher`, `umu-launcher`, `winboat`
- **Developer Focused**: Includes essential development environments and tools out of the box:
  - Homebrew (`brew`) support integrated into the base image
  - `distrobox`, `docker` & `docker-compose`
  - `nodejs`, `npm`, `rust`, `python-pip`, `python-pipx`
  - `visual-studio-code-bin`
- **Seamless Setup & Migration**: Features custom scripts to transition safely from other atomic distributions (`bopp-migrate`).
- **Hardware Encryption Utility**: Includes `bopp-tpm-refresh` to automatically re-enroll LUKS TPM2 encryption keys after system updates or migrations.
- **Enhanced Shell**: A pre-configured shell environment with `starship`, `zoxide`, and `eza` for a modern terminal experience.

## Custom Enhancements

- **Desktop First:** Stripped away Steam Deck/handheld-specific UI elements and scaling tweaks in favor of standard desktop environments (with support for KDE Plasma, GNOME, and Niri).
- **Developer Ready:** Pre-installed essentials like Distrobox, Homebrew (`brew`), Docker, VS Code, Node.js, Rust, and Python.
- **Streamlined Management:** Integrated `just` for simplified building and introduced custom tools for easy system administration:
  - **System Update Manager (`boppos-update`):** A comprehensive update script that seamlessly updates your OS (`bootc`), firmware, Flatpaks, Homebrew, and Distroboxes. Includes an interactive package diff preview.
    ```bash
    boppos-update
    ```
  - **Package Diff Tool (`bopp-diff`):** Analyzes the current running system against staged or upstream `bootc` images and provides a clear breakdown of upgraded, downgraded, added, or removed packages.
    ```bash
    sudo bopp-diff
    ```
  - **Kernel Arguments Manager (`bopp-kargs`):** A utility to easily view, edit, add, remove, and diff Boot Loader Specification (BLS) kernel arguments for your atomic deployments.
    ```bash
    sudo bopp-kargs help
    ```
  - **TPM Refresh:** Easily re-enroll LUKS/TPM2 decryption keys after system updates.
    ```bash
    bopp-tpm-refresh
    ```
  - **System Migration:** Transition your system from Fedora-based atomic distributions.
    ```bash
    sudo bopp-migrate
    ```
- **Optional Flatpaks (`install-optional-flatpaks`):** Includes an interactive script to easily fetch, customize, and install a curated list of essential Flatpak applications (sourced from Bazzite-DX and BoppOS). To use it, simply open your terminal and run:
  ```bash
  install-optional-flatpaks
  ```

## Migration Tool (`bopp-migrate`)

⚠️ **WARNING: HIGHLY EXPERIMENTAL AND POTENTIALLY DESTRUCTIVE** ⚠️

BoppOS includes an experimental migration script (`bopp-migrate`) designed to help users transition their `/etc` and `$HOME` configurations from a Fedora-based atomic OS (like Bazzite or Bluefin) to this Arch-based BoppOS image. 

**Do NOT run this script unless you fully understand what it does.** It will forcefully manipulate user IDs, group IDs, and move hidden configuration folders in your home directory into a backup "Vault". While it attempts to preserve critical data (like SSH keys, browser profiles, and game data), **it is largely untested and could result in a broken system or data loss.** Always ensure you have a separate, verified backup of your home directory before attempting a migration.

To use the migration tool, run it with `sudo` after booting into BoppOS for the first time:

```bash
sudo bopp-migrate
```

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

The OS is built using a multi-image architecture. You must first build the `base` image, and then build your preferred desktop environment flavor (`plasma`, `gnome`, or `niri`) on top of it.

### x86-64-v3 Build (v3 Default)

This build is compatible with most modern x86-64 hardware and is suitable for sharing or for use in CI/CD environments.

```bash
# 1. Build the base image
just build v3 base

# 2. Build your preferred flavor (e.g., plasma, gnome, niri)
just build v3 plasma
```

### x86-64-v4 Build (v4)

This enables optimizations for a wide range of modern CPUs (e.g., Intel Haswell and newer, AMD Excavator and newer) that support the x86-64-v4 microarchitecture level.

```bash
# 1. Build the base image
just build v4 base

# 2. Build your preferred flavor (e.g., plasma, gnome, niri)
just build v4 plasma
```

### Zen4/Zen5 Build (znver4)

If you are building on and for a system with an AMD Ryzen 7000 series CPU (or newer), you can enable native `znver4` optimizations for maximum performance.

```bash
# 1. Build the base image
just build znver4 base

# 2. Build your preferred flavor (e.g., plasma, gnome, niri)
just build znver4 plasma
```

### Switching to a Local Build

If you are building the image locally and want to apply it to your current system without pushing to a registry first, you can use the `just switch` command. This transfers the locally built container from your user environment to the root environment and tells `bootc` to switch to it via local storage.

```bash
# 1. Build the image
just build

# 2. Switch to the local v3 build
just switch

# (Optional) Switch to a specific architecture tag instead:
just switch v4
just switch znver4
```

## Acknowledgements

This project was made possible by the excellent work of the CachyOS team and the creators of the original [cachyos-deckify-bootc](https://github.com/lumaeris/cachyos-deckify-bootc) repository from which this was forked. It also stands on the shoulders of the [Bootcrew](https://github.com/bootcrew) and [bootc](https://github.com/containers/bootc) projects.
