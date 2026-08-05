# BoppOS Build & Maintenance Scripts

This directory contains the automation, build, and maintenance scripts for BoppOS (CachyOS-based bootc system).

## Script Catalog

### Core Container Build Scripts
- **`bootc-rootfs.sh`**: Initializes the ostree/bootc sysroot structure (`/sysroot`, `/ostree`, `/var`, `/home`, etc.) and sets up system layout during container image creation.
- **`setup_pacman_repos.sh`**: Imports repository signing keys (`/tmp/keys/*.asc`) and configures pacman mirrorlists and repository priorities.
- **`install_packages.sh`**: YAML-driven package installer that parses package manifests (`base.yaml`, `plasma.yaml`, `gnome.yaml`, `niri.yaml`) and executes optimized pacman installations.
- **`generate-package-list.sh`**: Queries pacman to generate package manifests (`all-packages.txt`, `cachyos-packages.txt`, `boppos-packages.txt`) for tracking installed packages.
- **`apply-update-intervals.sh`**: Sets `user.update-interval` and `user.component` xattr tags on filesystem paths based on `package-intervals.json`.

### Security & Auditing Scripts
- **`scan-pkg-cache.sh`**: Pre-build security scanner that audits downloaded pacman package `.pkg.tar.zst` archives and `.INSTALL` scriptlets for obfuscation, network calls, or credential harvesting.
- **`scan-image-ioc.sh`**: Post-build container image auditor that mounts built container filesystems to inspect for known threat indicators, suspicious systemd service units, eBPF artifacts, and dropped temp files.
- **`sign.sh`**: Signs built container image tags using `cosign` and exported keys.

### Utility & Data Scripts
- **`generate-icons.py`**: Generates standard Freedesktop icon sizes (`16x16` through `512x512`) from a source PNG image and installs them into `files/base/usr/share/icons/hicolor/`.
- **`fetch-update-intervals.py`**: Helper utility to aggregate and compute recommended update intervals for system packages into `package-intervals.json`.
- **`scrape-netinstall.py`**: Utility to scrape and inspect CachyOS Calamares netinstall package groups.
- **`package-intervals.json`**: Data file mapping package paths/components to their update interval policies.
- **`requirements.txt`**: Python dependencies required by utility scripts.
