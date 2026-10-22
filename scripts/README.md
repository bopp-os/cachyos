# BoppOS Build & Maintenance Scripts

This directory contains the automation, build, and maintenance scripts for BoppOS (CachyOS-based bootc system).

## Script Catalog

### Core Container Build Scripts
- **`bootc-rootfs.sh`**: Initializes the ostree/bootc sysroot structure (`/sysroot`, `/ostree`, `/var`, `/home`, etc.) and sets up system layout during container image creation.
- **`setup_pacman_repos.sh`**: Imports repository signing keys (`/tmp/keys/*.asc`) and configures pacman mirrorlists and repository priorities.
- **`install_packages.sh`**: YAML-driven package installer that parses package manifests (`base.yaml`, `plasma.yaml`, `gnome.yaml`, `niri.yaml`) and executes optimized pacman installations.
- **`generate-package-list.sh`**: Queries pacman to generate package manifests (`all-packages.txt`, `cachyos-packages.txt`, `boppos-packages.txt`) for tracking installed packages.
- **`apply-update-intervals.py`**: High-performance script setting `user.update-interval` and `user.component` xattr tags via direct Linux kernel syscalls and clamping system cache timestamps for layer determinism.
- **`compare-chunkah-layers.sh`**: Rechunks one image with two chunkah versions and reports how many layer digests the upgrade changes. Runs in the v3 PR build when the pin in `.github/chunkah/Containerfile` changes.

### Security & Auditing Scripts
- **`scan-pkg-cache.sh`**: Pre-build security scanner that audits downloaded pacman package `.pkg.tar.zst` archives and `.INSTALL` scriptlets for obfuscation, network calls, or credential harvesting.
- **`clamscan-prefetch.sh`**: Runs after the package prefetch and scans new package archives, the Homebrew files from the brew image, and the upstream base image rootfs with the `clamav/clamav` container. Clean packages (by SHA-256) and images (by ID) are recorded in `.clamav_scan_cache` at the root of the package cache, shared by all arches, and skipped on later runs.
- **`prefetch_extras.sh`**: Runs in the prefetch step. Saves what the offline builds need that is not a pacman package into hidden folders of the package cache: the Flathub remote definition (`.bootstrap/`) and a tarball of the latest commit of each kernel module repo listed in `kmod_sources.sh` (`.src/`, with the commit hash). The tarballs are ClamAV-scanned with the packages.
- **`kmod_sources.sh`**: The out-of-tree kernel module repositories, shared by `prefetch_extras.sh` and `build_kernel_modules.sh`.
- **`verify-package-cache.sh`**: Run after the base and flavor builds. Fails if the package cache holds an archive whose name and SHA-256 are not in the ClamAV record, i.e. a pacman call in the build downloaded a package after the prefetch scan.
- **`scan-image-ioc.sh`**: Post-build container image auditor that mounts built container filesystems to inspect for known threat indicators, suspicious systemd service units, eBPF artifacts, and dropped temp files.
- **`sign.sh`**: Signs built container image tags using `cosign` and exported keys.

### Utility & Data Scripts
- **`generate-icons.py`**: Generates standard Freedesktop icon sizes (`16x16` through `512x512`) from a source PNG image and installs them into `files/base/usr/share/icons/hicolor/`.
- **`fetch-update-intervals.py`**: Helper utility to aggregate and compute recommended update intervals for system packages into `package-intervals.json`.
- **`scrape-netinstall.py`**: Utility to scrape and inspect CachyOS Calamares netinstall package groups.
- **`package-intervals.json`**: Data file mapping package paths/components to their update interval policies. Lives on the `data` branch (updated weekly by `update-intervals.yml`); the build workflows and `just fetch-data` copy it here.
- **`requirements.txt`**: Python dependencies required by utility scripts.
