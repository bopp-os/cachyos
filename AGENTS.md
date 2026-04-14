# GuaraOS — Agent Context

Personal immutable atomic Linux images built on CachyOS + bootc.
Principles: **immutable by design · unbreakable by architecture · maximum runtime performance**.

---

## Stack

| Layer | Technology |
|---|---|
| Base OS | `docker.io/cachyos/cachyos-{v3,v4}` — Arch-based, performance-tuned |
| Image format | `bootc` (ostree) — atomic, rollback-capable |
| Build runtime | Podman — multi-stage Containerfiles |
| Layer optimizer | chunkah + zstd:chunked — OCI rechunking with chunk-level metadata for lazy pulls |
| Image signing | cosign — Sigstore keyful, `guaraos.pub` embedded in image |
| Package manager | pacman + CachyOS repos + Chaotic-AUR + AUR (build stage only) |
| Task runner | just (Justfile) |
| Display managers | GDM (gnome) · plasmalogin (gamestation) · cosmic-greeter (cosmic) |
| Swap | zswap (zstd + zsmalloc + shrinker, in-RAM pool) → 32 GiB `/var/swap/swapfile` (btrfs nested subvolume, first-boot) |

---

## Target Matrix

| Image | Arch | DM | Boot session | Purpose |
|---|---|---|---|---|
| `guaraos-gnome` | `znver4` | GDM | GNOME | Daily driver — AMD Ryzen 7000+ workstation |
| `guaraos-gamestation` | `znver4` | plasmalogin | gamescope → Plasma | Gaming rig — AMD Ryzen 7000+ |
| `guaraos-gamestation` | `v3` | plasmalogin | gamescope → Plasma | Gaming rig — generic x86-64 |
| `guaraos-cosmic` | `znver4` | cosmic-greeter | COSMIC | COSMIC desktop — AMD Ryzen 7000+ workstation |

Registry: `ghcr.io/guara92/guaraos-{flavor}:{arch}`

---

## Repository Layout

```text
Containerfile.base          shared base — all flavors FROM this
Containerfile.gnome         GNOME overlay
Containerfile.gamestation   KDE Plasma + gamescope overlay
Containerfile.cosmic        COSMIC desktop overlay
guaraos.pub                 cosign public key (baked into image as /etc/pki/containers/guaraos.pub)
Justfile                    build · push · sign · verify · switch
scripts/sign.sh             cosign signing helper (called by Justfile)
.github/workflows/
  build-znver4.yml          CI: guaraos-gnome:znver4 + guaraos-gamestation:znver4 + guaraos-cosmic:znver4
  build-v3.yml              CI: guaraos-gamestation:v3
files/base/                 overlay COPY'd into the base image
  etc/                      runtime-mutable /etc seeds
    containers/policy.json  container trust policy — ghcr.io/guara92 requires guaraos.pub
    profile.d/              cachyos-guaraos-{brew,distrobox,paths,wayland}.sh
    skel/                   default user shell configs (.bashrc, .bashrc.d/)
    zsh/zshrc
    sysctl.d/
      99-guaraos.conf         vm.max_map_count, inotify, zone_reclaim, swappiness, BBR
  usr/
    bin/                    user-facing scripts
      guara-migrate         migrate from Bazzite/Fedora to GuaraOS using systemd-homed
      guaraos-update        orchestrate bootc + fwupd + flatpak + brew + distrobox updates
      guara-install-flatpaks    install Flatpaks from curated list + Bazzite-DX upstream
      install-optional-flatpaks (compat wrapper → guara-install-flatpaks)
    lib/bootc/kargs.d/
      90-guaraos-optimizations.toml   kernel args (see Kernel Args section)
    lib/systemd/system/
      var-opt.mount                    OverlayFS mount for /opt (writable on immutable system)
      usr-share-sddm.mount             OverlayFS mount for SDDM theme dir
      guaraos-swap-setup.service       first-boot oneshot: creates /var/swap as btrfs subvolume + swapfile
      guaraos-snapper-setup.service    first-boot oneshot: creates snapper root config + .snapshots subvolume
    lib/tmpfiles.d/
      guaraos-opt-overlay.conf
      guaraos-sddm-overlay.conf
    libexec/
      assign-usercomponent.sh      tags pacman-owned files with setfattr user.component
      guaraos-swap-setup           creates /var/swap btrfs subvolume + 32 GiB swapfile on first boot
      guaraos-snapper-setup        creates snapper 'root' config (template: guaraos) on first boot
    etc/snapper/
      config-templates/guaraos     GuaraOS snapper template (daily 7-day window, 20% space limit)
    share/guaraos/
      guaraos-flatpaks.txt  curated Flatpak list for guara-install-flatpaks
    share/fish/vendor_conf.d/cachyos-guaraos.fish
files/gamestation/          overlay COPY'd into the gamestation image (on top of base)
  usr/lib/plasmalogin/
    defaults.conf           managed default: DefaultSession=gamescope-session.desktop
  usr/lib/systemd/system/
    guaraos-gamestation-setup.service   first-boot oneshot autologin writer
  usr/libexec/
    guaraos-gamestation-setup           detects first user → writes plasmalogin autologin
  etc/
    sysctl.d/
      99-guaraos-gamestation.conf   sched_autogroup_enabled=0 for game-dominant workloads
    pipewire/pipewire.conf.d/
      99-guaraos-latency.conf       512-sample quantum (~10ms) for low-latency gaming audio
```

---

## Build Pipeline (multi-stage, Containerfile.base)

```text
Stage 1: aur_builder  (cachyos-{arch})
  - Initialises pacman keyring + CachyOS + Chaotic-AUR repos
  - Builds AUR packages: scopebuddy-git, autofs, heroic-games-launcher-bin
  - Clones bootcrew/mono (shared bootc setup scripts)

Stage 2: brew  (ghcr.io/ublue-os/brew:latest)
  - Source of the Homebrew tarball (copied into system stage)

Stage 3: system  (cachyos-{arch})   ← final image
  - Imports pacman config + keyrings from aur_builder
  - Installs ~25 categorised package groups (see Key Packages)
  - COPYs files/base/ overlay
  - Installs AUR packages from aur_builder
  - Generates initramfs with dracut (bootc + ostree modules)
  - Runs bootc container lint
```

Flavor overlays (`Containerfile.gnome`, `Containerfile.gamestation`, `Containerfile.cosmic`) are:

```text
FROM ghcr.io/guara92/guaraos-base:{arch}
  → install DE packages
  → COPY files/{flavor}/ overlay
  → enable/disable systemd units
```

---

## Core Principles — INVIOLABLE

### 1. Immutable by Design

- `/usr` is **read-only at runtime**. The only way to change it is to rebuild and push a new image, then `bootc upgrade`.
- `/etc` is a writable mutable overlay (ostree). Ship seeds in `files/*/etc/`; first-boot services write runtime config here.
- `/var` is writable and persistent across upgrades. User data lives here.
- `/opt` is provided via OverlayFS (`var-opt.mount`): lower=`/usr/lib/opt`, upper=`/var/opt_overlay/upper`.

### 2. Unbreakable by Architecture

- Every update is a complete atomic image swap. No partial states.
- `bootc` maintains staged + active deployments. Bad update → `bootc rollback`.
- All images are cosign-signed and verified by the embedded `guaraos.pub` policy before `bootc upgrade` applies them.
- `bootc container lint` runs at the **end of every base build** — a lint failure aborts the build.
- Initramfs hooks (`mkinitcpio`, `dracut-install`) are **null-linked** during the build to prevent redundant generation. Dracut is called explicitly once at the end.

### 3. Maximum Runtime Performance

- **Kernel**: `linux-cachyos` — CachyOS performance-patched kernel (BORE scheduler, MGLRU, THP, etc.)
- **CPU scheduler**: `scx_loader.service` enabled — SCX userspace schedulers (`scx-scheds-git`, `scx-tools-git`, `scx-manager`) for latency-optimal scheduling on modern CPUs
- **znver4 arch**: packages reinstalled from CachyOS znver4 repos at build time → native Zen 4/5 instruction set, no x86-64-v3 ceiling
- **Kernel args + sysctl** (see below): mitigations off, AMD P-state active, full preemption, IOMMU passthrough, THP madvise, threaded IRQs, Zen 4 NUMA tuning, BBR networking
- **ananicy-cpp**: `ananicy-cpp.service` enabled — automatic process priority management
- **dmemcg-booster**: enabled for memory cgroup performance
- **zswap**: enabled via kargs (`zstd` compressor, `zsmalloc` pool, shrinker enabled) — compressed in-RAM swap cache; backed by a 32 GiB `/var/swap/swapfile` on first boot. `/var/swap` is created as a dedicated **btrfs nested subvolume** by `guaraos-swap-setup.service` — required by two complementary kernel restrictions: (a) a subvolume containing an **active** swapfile cannot be snapshotted, and (b) a swapfile that has been snapshotted cannot be activated (`swapon` fails). By isolating the swapfile in its own nested subvolume, snapper only ever snapshots `@` — nested subvolumes appear as empty directories in `@` snapshots and are never themselves snapshotted, so neither restriction is ever triggered. **Prerequisite**: btrfs swapfiles require a **single-device filesystem** with a **single data profile** (default for any single-drive install; RAID configurations are unsupported by the kernel swap subsystem). `vm.swappiness=40` — moderate pressure to push anonymous pages into the pool, keeps hot game/app data resident in RAM; lower than zram-tuned 100, higher than pure-disk-swap 10.
- **snapper**: daily timeline snapshots (7-day rolling window) of the mutable state — `/etc` config changes and `/var` app state. `/usr` is read-only (bootc-managed), so snapshot diffs are small. First-boot `guaraos-snapper-setup.service` creates the snapper `root` config using the `guaraos` template and the `.snapshots` nested subvolume. `btrfs-assistant` provides the GUI.

### 4. Performance — Kernel Arguments

Declared in `files/base/usr/lib/bootc/kargs.d/90-guaraos-optimizations.toml`:

```toml
amd_pstate=active            AMD CPU P-state driver (better freq scaling)
amdgpu.ppfeaturemask=0xffffffff  unlock all AMDGPU power features
split_lock_detect=off        eliminate split-lock detection overhead
nowatchdog                   disable hardware watchdog (latency reduction)
nmi_watchdog=0               disable NMI watchdog (latency reduction)
mitigations=off              disable Spectre/Meltdown mitigations (trusted hardware)
sysrq_always_enabled=1
usbcore.autosuspend=-1       disable USB autosuspend (gaming peripherals)
iommu=pt                     IOMMU passthrough (PCIe latency)
preempt=full                 full kernel preemption (desktop responsiveness)
amdgpu.gpu_recovery=1
transparent_hugepage=madvise
transparent_hugepage.defrag=defer+madvise
skew_tick=1                  stagger per-CPU timer expiry — reduces lock contention on multi-CCD Ryzen
threadirqs                   threaded IRQ handlers — IRQs schedulable with priority, reduces audio/frame latency
zswap.enabled=1              enable zswap compressed swap cache
zswap.compressor=zstd        zstd compression (best ratio/speed tradeoff)
zswap.zpool=zsmalloc         zsmalloc pool allocator (lower fragmentation than zbud)
zswap.shrinker_enabled=1     proactively decompress pool pages back to RAM when RAM is free (Linux 6.8+)
```

---

## Gamestation Autologin Mechanism

Two-layer approach (username unknown at build time):

**Layer 1 — build time** (`/usr/lib/plasmalogin/defaults.conf`, read-only):

```ini
[General]
DefaultSession=gamescope-session.desktop
```

Pre-selects gamescope in the greeter. Active immediately, even before user creation.

**Layer 2 — first boot** (`guaraos-gamestation-setup.service`):
- `ConditionPathExists=!/etc/plasmalogin.conf.d/autologin.conf`
- Runs every boot until the drop-in exists, then never again.
- Script finds first real user (`getent passwd`, UID 1000–65533).
- If no user yet: exits 0, retries next boot.
- Writes `/etc/plasmalogin.conf.d/autologin.conf`:

```ini
[Autologin]
User=<detected>
Session=gamescope-session.desktop
```

After first boot completes: subsequent boots skip the greeter entirely → straight into gamescope/Steam.

---

## Gamestation Runtime Optimizations

Beyond the autologin mechanism, the gamestation image ships additional performance configs:

| Config | Path | Effect |
|---|---|---|
| `sched_autogroup_enabled=0` | `/etc/sysctl.d/99-guaraos-gamestation.conf` | Disables scheduler autogroups so the game process gets unthrottled CPU access |
| PipeWire 512-sample quantum | `/etc/pipewire/pipewire.conf.d/99-guaraos-latency.conf` | Halves audio latency from ~21ms to ~10ms at 48kHz |

---

## Key Packages (base image)

| Category | Packages |
|---|---|
| Kernel | `linux-cachyos` `linux-cachyos-headers` |
| CPU scheduler | `scx-scheds-git` `scx-tools-git` `scx-manager` |
| Bootc | `bootc` `dracut` `ostree` `skopeo` `containers-common` |
| User management | `systemd-homed` `pam_systemd_home.so` |
| Gaming | `cachyos-gaming-meta` `cachyos-gaming-applications` `gamescope-session-git` `proton-cachyos` `wine` `steam` `lutris` `mangohud` `goverlay` `lact` `coolercontrol` `openrgb` `sunshine` `waydroid` `protonup-qt` |
| Graphics | `mesa-git` `lib32-mesa-git` `vulkan-radeon` `vulkan-intel` `vulkan-nouveau` + lib32 variants |
| Containers | `docker` `docker-compose` `podman` `podman-compose` `distrobox` `flatpak` |
| Virtualization | `qemu-full` `libvirt` `virt-install` `virt-viewer` `edk2-ovmf` `swtpm` |
| Performance | `bpftune-git` `dmemcg-booster` `ananicy-cpp` `scx_loader` |
| Swap | zswap via kargs · `guaraos-swap-setup.service` (first-boot: `/var/swap` btrfs subvolume + 32 GiB swapfile) |
| Btrfs snapshots | `snapper` `btrfs-assistant` `cachyos-snapper-support` `btrfsmaintenance` · `guaraos-snapper-setup.service` (first-boot config) · `snapper-timeline.timer` (daily 7-day window) · `btrfs-scrub.timer` + `btrfs-balance.timer` (monthly, idle priority) |
| Dev languages | `nodejs` `npm` `rust` `go` `python-pip` `python-pipx` `ruby` `cargo-binstall` |
| Dev tools | `base-devel` `git` `git-lfs` `github-cli` `paru` `just` `cosign` `visual-studio-code-bin` |
| Text editors | `vim` `helix` `micro` `nano` `visual-studio-code-bin` |
| Shell | `zoxide` `eza` `starship` `atuin` `fzf` `ripgrep` `fd` `btop` `fastfetch` |
| Brew | via `ublue-os/brew` + `brew-setup.service` |
| AUR (built) | `scopebuddy-git` `autofs` `heroic-games-launcher-bin` |
| GNOME extras | `easyeffects` `lsp-plugins` `gdm-settings` `flat-remix-gnome` `flat-remix-gtk` |

---

## Naming Conventions

| Concept | Pattern | Examples |
|---|---|---|
| Images | `guaraos-{flavor}` | `guaraos-gnome` `guaraos-gamestation` |
| Registry tags | `ghcr.io/guara92/guaraos-{flavor}:{arch}` | `:znver4` `:v3` |
| User scripts | `guara-*` | `guara-migrate` |
| System scripts | `guaraos-*` | `guaraos-update` `guaraos-gamestation-setup` |
| Config files | `guaraos-*` | `guaraos-opt-overlay.conf` |
| kargs files | `90-guaraos-*.toml` | `90-guaraos-optimizations.toml` |
| Build cache IDs | `guaraos-{builder-,}cache-{arch}` | `guaraos-cache-znver4` |
| Signing key | `guaraos.pub` (repo root + `/etc/pki/containers/`) | |
| profile.d scripts | `cachyos-guaraos-*.sh` | `cachyos-guaraos-brew.sh` |

---

## Build Commands

```bash
# Always build base first for a given arch
just build znver4 base
just build znver4 gnome
just build znver4 gamestation
just build znver4 cosmic

just build v3 base
just build v3 gamestation

# Verify cosign signatures after push
just verify znver4
just verify v3

# Rebase running system to a local build
just switch znver4 gnome
just switch znver4 gamestation
just switch znver4 cosmic
```

---

## CI Workflows

| Workflow | Runner requirement | Images built |
|---|---|---|
| `build-znver4.yml` | Self-hosted, AVX-512 / znver4 | `guaraos-base:znver4` `guaraos-gnome:znver4` `guaraos-gamestation:znver4` `guaraos-cosmic:znver4` |
| `build-v3.yml` | Self-hosted, AVX2 | `guaraos-base:v3` `guaraos-gamestation:v3` |

Both workflows:
1. Build base → rechunk base → build flavor(s) → rechunk flavors
2. Push all tags with `--compression-format=zstd:chunked --compression-level=3`
3. Sign each image digest with `SIGNING_SECRET` (cosign private key in GitHub Actions secret)
4. Clean workspace and prune Podman storage

Triggers: `schedule` (every 2 days) + `workflow_dispatch`. `build-v3.yml` also triggers on PR to `main`.

---

## What Agents Must Never Do

- **Never install packages at runtime.** Add them to the appropriate Containerfile and rebuild.
- **Never write to `/usr` at runtime.** It is read-only. Write to `/etc` (mutable overlay) or `/var` instead.
- **Never hardcode usernames** in config files baked into the image. Use `getent passwd` in first-boot services.
- **Never re-enable initramfs hooks** (`90-mkinitcpio-install.hook`, `90-dracut-install.hook`). They are intentionally null-linked. Dracut runs once explicitly at the end of `Containerfile.base`.
- **Never add SDDM** to the gamestation image. The display manager is `plasmalogin`.
- **Never add plasmalogin** to the gnome image. The display manager is GDM.
- **Never add GDM or plasmalogin** to the cosmic image. The display manager is `cosmic-greeter`.
- **Never remove `bootc container lint`** from `Containerfile.base`. It is the final validation gate.
- **Never push to the git remote.** All remote operations are handled by CI.
- **Never remove the `cosign.pub → guaraos.pub` COPY** from `Containerfile.base`. It is what makes `bootc upgrade` trust signed updates.
- **Never place files under `/opt` directly** in a Containerfile. Place them in `/usr/lib/opt/`; the `var-opt.mount` OverlayFS exposes them at `/opt` at runtime.
- **Never skip the `if [ -e /usr/etc ]` cleanup block** after pacman installs. CachyOS packages occasionally write stale `/usr/etc` files that break `bootc`.
- **Never disable `systemd-homed.service`** in the base image. User accounts depend on it.
- **Never add LUKS or TPM2 kernel arguments** (`rd.luks.options=tpm2-device=auto`). GuaraOS machines are trusted desktops with no disk encryption.
- **Never write the swapfile to `/usr`**. `/var/swap/swapfile` is the correct path — `/var` is persistent across upgrades. The file is created at runtime by `guaraos-swap-setup.service`, not baked into the image.
- **Never enable zram**. GuaraOS uses zswap + disk swapfile. zram and zswap are mutually exclusive swap compression strategies; enabling both wastes RAM.
- **Never create `/var/swap` as a plain directory on btrfs**. It must be a dedicated nested btrfs subvolume (created by `guaraos-swap-setup`). The kernel enforces two restrictions: (a) a subvolume with an active swapfile cannot be snapshotted, and (b) a swapfile that has been snapshotted cannot be activated. A plain directory inside `@` would be snapshotted by snapper, triggering restriction (b) and causing `swapon` to fail permanently. A nested subvolume is excluded from `@` snapshots, so neither restriction ever fires.
- **Never configure snapper to directly snapshot the subvolume that contains the swapfile**. The swapfile lives in its own `@/var/swap` nested subvolume; snapper targets `@`. Nested subvolumes appear as empty directories in `@` snapshots — `@/var/swap` is never included. If snapper were ever pointed at `@/var/swap` directly, the active swapfile would block snapshot creation (kernel restriction a), and any snapshot taken while the swap was inactive would permanently block future `swapon` (kernel restriction b).
- **Never remove `guaraos-snapper-setup.service`** without also removing snapper entirely. Without it, no `.snapshots` subvolume is created and snapper-timeline.timer will error on every boot.

---

## Adding a New Flavor

1. Create `Containerfile.{flavor}` — `FROM ghcr.io/guara92/guaraos-base:${BASE_IMAGE_TAG}`.
2. Create `files/{flavor}/` with overlay files for `etc/` and `usr/`.
3. Add `{flavor}` to the `FLAVORS` array in the appropriate workflow(s).
4. Add `{flavor}` to the `FLAVORS` array in the `verify` recipe in `Justfile`.
5. Document the new target in `README.md`.

Implemented flavors: `guaraos-gnome`, `guaraos-gamestation`, `guaraos-cosmic`.
No further flavors are currently planned. Hyprland or a minimal variant may be considered in the future.
