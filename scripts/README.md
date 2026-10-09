# BoppOS Build & Maintenance Scripts

This directory contains the automation, build, and maintenance scripts for BoppOS (CachyOS-based bootc system).

## Script Catalog

### Core Container Build Scripts
- **`bootc-rootfs.sh`**: Initializes the ostree/bootc sysroot structure (`/sysroot`, `/ostree`, `/var`, `/home`, etc.) and sets up system layout during container image creation.
- **`setup_pacman_repos.sh`**: Imports repository signing keys (`/tmp/keys/*.asc`) and configures pacman mirrorlists and repository priorities.
- **`install_packages.sh`**: YAML-driven package installer that parses package manifests (`base.yaml`, `plasma.yaml`, `gnome.yaml`, `niri.yaml`) and executes optimized pacman installations.
- **`build_kernel_modules.sh`**: Builds out-of-tree kernel modules (nct6687d, it87, xpadneo, xone, zenergy) against the installed kernel headers without DKMS.
- **`build_initramfs.sh`**: Runs depmod and dracut for the installed kernel, then tags `/usr/lib/modules` so the initramfs and out-of-tree modules get their own chunkah components while stock modules keep the `linux-cachyos` package tag. Dracut config lives in `files/base/usr/lib/dracut/dracut.conf.d/`.
- **`generate-package-list.sh`**: Queries pacman to generate package manifests (`all-packages.txt`, `cachyos-packages.txt`, `boppos-packages.txt`) for tracking installed packages.
- **`apply-update-intervals.py`**: High-performance script setting `user.update-interval` and `user.component` xattr tags via direct Linux kernel syscalls and clamping system cache timestamps for layer determinism.
- **`compare-chunkah-layers.sh`**: Rechunks one image with two chunkah versions and reports how many layer digests the upgrade changes. Runs in the v3 PR build when the pin in `.github/chunkah/Containerfile` changes.

### Security & Auditing Scripts
- **`scan-pkg-cache.sh`**: Pre-build security scanner for downloaded pacman packages. Reads each package's `.MTREE` to check for known IOC paths, then scans its `.INSTALL` scriptlet and any ALPM hooks/scripts it ships for obfuscation, network droppers, or credential access (plus YARA when installed). Clean packages are cached by SHA-256; bump `SCAN_VERSION` when the checks change.
- **`scan-image-ioc.sh`**: Post-build image auditor. From one walk of the mounted image it checks IOC paths, payload sizes, temp-dir drops, setuid/setgid files against `files/security/setuid-allowlist.txt` (warning), package scriptlets, ALPM scripts, `profile.d`, and `Exec*=` lines in system/user units, ALPM hooks and autostart entries.
- **`scan-patterns.sh`**: Heuristics shared by both scanners (sourced). Rerun them against a real image's scriptlets, hooks and units before widening, to keep builds free of false positives.
- **`sign.sh`**: Signs built container image tags using `cosign` and exported keys.

### Utility & Data Scripts
- **`generate-icons.py`**: Generates standard Freedesktop icon sizes (`16x16` through `512x512`) from a source PNG image and installs them into `files/base/usr/share/icons/hicolor/`.
- **`fetch-update-intervals.py`**: Helper utility to aggregate and compute recommended update intervals for system packages into `package-intervals.json`.
- **`scrape-netinstall.py`**: Utility to scrape and inspect CachyOS Calamares netinstall package groups.
- **`package-intervals.json`**: Data file mapping package paths/components to their update interval policies.
- **`requirements.txt`**: Python dependencies required by utility scripts.
