[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/M4M81TUBKF)

# CachyOS BoppOS 🚀

**A high-performance, desktop-focused atomic (`bootc`) Linux image based on CachyOS.**

CachyOS BoppOS is a custom-built OS designed for high-end desktop gaming and development. It's a fork of `cachyos-deckify-bootc`, transformed from a handheld-oriented system into a powerful, desktop-first experience.

This is all very experimental. So use at your own risk.

---

## What's Changed (vs. Upstream)

- **Desktop First:** Stripped away Steam Deck/handheld-specific UI elements and scaling tweaks in favor of a standard KDE Plasma desktop.
- **Developer Ready:** Pre-installed essentials like Docker, VS Code, Node.js, Rust, and Python.
- **Streamlined Management:** Integrated `just` for simplified building and introduced a custom `boppos-update` script for seamless OS updates.

## Key Features

- **High-Performance Base**: Built on [CachyOS](https://cachyos.org/), an Arch-based distribution with performance-tuned kernels and repositories.
- **Atomic & Immutable**: Uses [bootc](https://bootc-dev.github.io/) for an atomic, image-based system that offers incredible stability and easy rollbacks.
- **Desktop Optimized**: Stripped of all handheld UI elements and optimized for a traditional desktop experience with KDE Plasma.
- **Modern Hardware Support**: Includes build-time support for `znver4` CPU optimizations for AMD Ryzen 7000 series processors.
- **Gaming Ready**: Comes with a suite of pre-installed gaming software and utilities:
  - `cachyos-gaming-applications`, `proton-cachyos`, `wine-cachyos`
  - `sunshine`, `mangohud`, `goverlay`, `lact`
  - `faugus-launcher`, `umu-launcher`, `winboat`
- **Developer Focused**: Includes essential development tools out of the box:
  - `docker` & `docker-compose`
  - `nodejs`, `npm`, `rust`, `python-pip`, `python-pipx`
  - `visual-studio-code-bin`
- **Enhanced Shell**: A pre-configured shell environment with `starship`, `zoxide`, and `eza` for a modern terminal experience.

## Build Instructions

CachyOS BoppOS uses `just` as a command runner to simplify the build process. Ensure you have `just` and `podman` installed.

### x86-64-v3 Build (v3 Default)

This build is compatible with most modern x86-64 hardware and is suitable for sharing or for use in CI/CD environments.

```bash
just build
```

### x86-64-v4 Build (v4)

This enables optimizations for a wide range of modern CPUs (e.g., Intel Haswell and newer, AMD Excavator and newer) that support the x86-64-v4 microarchitecture level.

```bash
just build v4
```

### Zen4/Zen5 Build (znver4)

If you are building on and for a system with an AMD Ryzen 7000 series CPU (or newer), you can enable native `znver4` optimizations for maximum performance.

```bash
just build znver4
```

## Installation & Switching

This image is designed to be managed by `bootc`. You can either perform a fresh installation on a new system or switch an existing `bootc`-based OS to BoppOS without losing your data.

### Fresh Installation

After building the container image, you can:

1.  Push it to a container registry (like `ghcr.io`, `quay.io`, or a local registry).
2.  Use `bootc install` from a live environment to install CachyOS BoppOS to a target disk.

For detailed installation instructions, refer to the [official bootc documentation](https://bootc-dev.github.io/book/installation.html).

A typical installation command would look like this:

```bash
# Example:
bootc install to-disk --image ghcr.io/ripps818/cachyos-boppos-bootc:latest /dev/sdX
```

### Switching from an Existing bootc OS (e.g., Bazzite)

If you are already running a `bootc`-based system, you can switch to BoppOS directly without needing to reformat or reinstall. This is one of the major advantages of `bootc`.

To switch, run the following command, pointing to the BoppOS image in your registry:

```bash
sudo bootc switch ghcr.io/ripps818/cachyos-boppos-bootc:latest
```

Your system will download the new image and stage it for the next boot.

**Note on Signature Verification**: For a secure transition, you may need to configure your system to trust the signature of the new image. The `Containerfile` includes a `cosign.pub` key and `policy.json`, which you may need to adapt for your registry and signing setup.

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
