# BoppOS Containerfile
#
# A high-performance, desktop-focused atomic image based on CachyOS.
# Derived from cachyos-deckify-bootc.

# ==========================================
# STAGE 1: AUR Builder
# ==========================================
ARG TARGET_CPU_MARCH=v3
ARG BASE_IMAGE_TAG=v3

FROM docker.io/cachyos/cachyos-${BASE_IMAGE_TAG} AS aur_builder
ARG TARGET_CPU_MARCH
ARG BASE_IMAGE_TAG
USER root

# Minimal setup: just enough to build packages
# Dynamic cache ID ensures builder isolation for different architectures
RUN --mount=type=cache,id=boppos-builder-cache-${TARGET_CPU_MARCH},target=/var/cache/pacman/pkg \
    pacman-key --init && \
    pacman-key --populate archlinux cachyos && \
    pacman-key --recv-keys F3B607488DB35A47 5DE6BF3EBC86402E7A5C5D241FA48C960F9604CB 3056513887B78AEB --keyserver keyserver.ubuntu.com && \
    pacman-key --lsign-key F3B607488DB35A47 && \
    pacman-key --lsign-key 5DE6BF3EBC86402E7A5C5D241FA48C960F9604CB && \
    pacman-key --lsign-key 3056513887B78AEB && \
    sed -i 's/^#*ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf && \
    pacman -Sy --noconfirm --needed cachyos-keyring archlinux-keyring cachyos-mirrorlist cachyos-v3-mirrorlist cachyos-v4-mirrorlist cachyos-hooks chwd cachyos-rate-mirrors lsb-release && \
    pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' && \
    cachyos-rate-mirrors && \
    echo -e '\n[bootc]\nSigLevel = Required\nServer=https://github.com/hecknt/arch-bootc-pkgs/releases/download/$repo' >> /etc/pacman.conf && \
    echo -e '\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist' >> /etc/pacman.conf && \
    if [ "$TARGET_CPU_MARCH" = "znver4" ]; then \
        printf "[cachyos-znver4]\nInclude = /etc/pacman.d/cachyos-v4-mirrorlist\n\n[cachyos-core-znver4]\nInclude = /etc/pacman.d/cachyos-v4-mirrorlist\n\n[cachyos-extra-znver4]\nInclude = /etc/pacman.d/cachyos-v4-mirrorlist\n\n" > /tmp/znver4-repos.conf && \
        awk -v repo_file="/tmp/znver4-repos.conf" '/^#?\[cachyos-v4\]/ && !done { system("cat " repo_file); done=1 } { print }' /etc/pacman.conf > /etc/pacman.conf.tmp && \
        mv /etc/pacman.conf.tmp /etc/pacman.conf && \
        rm -f /tmp/znver4-repos.conf ; \
    fi && \
    pacman -Syu --noconfirm --needed base-devel git sudo && \
    useradd -m builduser && \
    echo "builduser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers && \
    mkdir -p /home/builduser/packages && \
    chown -R builduser:builduser /home/builduser

# Build Scopebuddy
RUN --mount=type=cache,id=boppos-builder-cache-${TARGET_CPU_MARCH},target=/var/cache/pacman/pkg \
    git clone https://aur.archlinux.org/scopebuddy-git.git /tmp/scopebuddy && \
    chown -R builduser:builduser /tmp/scopebuddy && \
    cd /tmp/scopebuddy && \
    sudo -u builduser PKGDEST=/home/builduser/packages makepkg --noconfirm -s --skipinteg

# Build autofs
RUN --mount=type=cache,id=boppos-builder-cache-${TARGET_CPU_MARCH},target=/var/cache/pacman/pkg \
    git clone https://aur.archlinux.org/autofs.git /tmp/autofs && \
    chown -R builduser:builduser /tmp/autofs && \
    cd /tmp/autofs && \
    sudo -u builduser PKGDEST=/home/builduser/packages makepkg --noconfirm -s --skipinteg

# Build pacman-ostree
RUN --mount=type=cache,id=boppos-builder-cache-${TARGET_CPU_MARCH},target=/var/cache/pacman/pkg \
    pacman -Sy --noconfirm --needed ostree rust arch-install-scripts bootc && \
    git clone https://aur.archlinux.org/pacman-ostree.git /tmp/pacman-ostree && \
    cd /tmp/pacman-ostree && \
    # Inject the Cargo.toml fix directly into the PKGBUILD so it runs after source extraction
    sed -i 's/^\([[:space:]]*\)\(cargo .*\)/\1sed -i "s|4.0.3|5.0.0|g" Cargo.toml \&\& cargo update -p alpm \&\& \2/' PKGBUILD && \
    chown -R builduser:builduser /tmp/pacman-ostree && \
    sudo -u builduser PKGDEST=/home/builduser/packages makepkg --noconfirm -s --skipinteg

# ==========================================
# STAGE 2: System Build
# ==========================================
FROM docker.io/cachyos/cachyos-${BASE_IMAGE_TAG} AS system
ARG TARGET_CPU_MARCH
ARG BASE_IMAGE_TAG
ENV LANG=en_US.UTF-8

# Copy Homebrew
COPY --from=ghcr.io/ublue-os/brew:latest /system_files /
RUN setfattr -n user.component -v "homebrew" "/usr/share/homebrew.tar.zst"

# Copy configured pacman environment from aur_builder
COPY --from=aur_builder /etc/pacman.conf /etc/pacman.conf
COPY --from=aur_builder /etc/pacman.d /etc/pacman.d

# Ensure the log file exists
RUN touch /var/log/pacman.log

# Move pacman directories for bootc/usroverlay compatibility
RUN grep "= */var" /etc/pacman.conf | sed "/= *\/var/s/.*=// ; s/ //" | xargs -n1 sh -c 'mkdir -p "/usr/lib/sysimage/$(dirname $(echo $1 | sed "s@/var/@@"))" && mv -v "$1" "/usr/lib/sysimage/$(echo "$1" | sed "s@/var/@@")"' '' && \
    sed -i -e "/= *\/var/ s/^#//" -e "s@= */var@= /usr/lib/sysimage@g" -e "/DownloadUser/d" -e "/^#IgnorePkg/a IgnorePkg = mesa-git lib32-mesa-git" /etc/pacman.conf

# PRE-INSTALL CONFIGURATION & HOOKS
# Copy hooks and configs EARLY so they fire during the master pacman block.
COPY files/usr/share /usr/share
COPY files/etc /etc
COPY files/usr/lib /usr/lib

# Generate en_US.UTF-8 locale
RUN sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
    locale-gen && \
    echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Dracut i18n fix
RUN mkdir -p /usr/lib/dracut/dracut.conf.d && \
    echo 'i18n_vars="/usr/share/kbd/consolefonts  /usr/share/kbd/keymaps"' >> /usr/lib/dracut/dracut.conf.d/boppos-cachyos.conf

# ==========================================
# CPU ARCHITECTURE REPOSITORY SETUP
# ==========================================
RUN --mount=type=cache,id=boppos-cache-${TARGET_CPU_MARCH},target=/usr/lib/sysimage/cache/pacman/pkg \
    # Surgical Cleanup: Remove partials and old metadata for this tier's cache
    # lua is a package that often causes issues if left in a half-updated state, so we target it specifically.
    rm -f /usr/lib/sysimage/cache/pacman/pkg/lua* && \
    rm -f /usr/lib/sysimage/cache/pacman/pkg/*.part && \
    pacman -Sc --noconfirm && \
    if [ "$TARGET_CPU_MARCH" = "znver4" ]; then \
        echo "Architecture $TARGET_CPU_MARCH detected. Reinstalling packages for Zen 4/5 optimization..." && \
        pacman -Syy && \
        # Reinstall all packages using command substitution to avoid pipe-stdin issues
        PKGS=$(pacman -Qqn) && pacman -S --noconfirm $PKGS ; \
    else \
        echo "Architecture $TARGET_CPU_MARCH detected. Using standard image repositories." ; \
    fi && \
    pacman -Syu --noconfirm

# Remove base kernels/handheld packages if present in the base image
RUN --mount=type=tmpfs,dst=/run \
    pacman -Rns --noconfirm linux linux-cachyos-deckify linux-cachyos-deckify-headers cachyos-handheld plasma-login-manager || echo "Unwanted base packages not found, skipping."

# Ensure Discover and PackageKit are completely removed so the OS relies purely on bootc/flatpak
RUN --mount=type=tmpfs,dst=/run \
    pacman -Rns --noconfirm discover packagekit packagekit-qt5 packagekit-qt6 || echo "Discover/PackageKit not found, skipping."

# ==========================================
# MASTER PACKAGE INSTALLATION
# ==========================================
RUN --mount=type=tmpfs,dst=/run \
    --mount=type=cache,id=boppos-cache-${TARGET_CPU_MARCH},target=/usr/lib/sysimage/cache/pacman/pkg \
    pacman -Sy --noconfirm --needed \
        # --- System Core ---
        linux-cachyos linux-cachyos-headers systemd systemd-sysvcompat \
        dbus dbus-broker-units dbus-glib glib2 polkit shadow lua-luv fuse2 fuse3 fuse2fs \
        dracut ostree bootc skopeo amd-ucode intel-ucode linux-firmware sof-firmware \
        libdisplay-info lib32-libdisplay-info \
        # --- Graphics & Drivers ---
        mesa lib32-mesa mesa-utils vulkan-icd-loader vulkan-radeon lib32-vulkan-radeon vulkan-tools \
        # --- Desktop Environment & Display Manager ---
        plasma-desktop plasma-workspace xorg-xwayland plasma-pa plasma-nm \
        qt5-wayland qt6-wayland breeze-gtk cachyos-emerald-kde-theme-git cachyos-plymouth-theme \
        cachyos-plymouth-bootanimation dolphin konsole sddm sddm-kcm cachyos-themes-sddm \
        powerdevil kscreen kdeconnect ark ffmpegthumbnailer \
        polkit polkit-kde-agent kwallet-pam udisks2 ptyxis \
        xdg-desktop-portal xdg-desktop-portal-kde kate python-gobject \
        ffmpegthumbs kdegraphics-thumbnailers kimageformats qt6-imageformats \
        kio-extras kio-fuse kio-admin kde-gtk-config colord-kde \
        flatpak-kcm partitionmanager plasma-disks plasma-systemmonitor spectacle \
        # --- Fonts & Themes ---
        ttf-ms-fonts ttf-dejavu ttf-bitstream-vera noto-fonts noto-fonts-emoji noto-fonts-cjk \
        ttf-jetbrains-mono ttf-fira-code ttf-cascadia-code \
        cachyos-settings cachyos-kde-settings cachyos-micro-settings cachyos-wallpapers \
        # --- Power & Hardware Management ---
        power-profiles-daemon cpupower upower accountsservice rtkit xdg-user-dirs mousetweaks radeontool \
        # --- Gaming Core & Utilities ---
        steam lutris heroic-games-launcher-bin gamescope xdotool yad \
        cachyos-gaming-applications faugus-launcher umu-launcher proton-cachyos wine-cachyos winboat \
        sunshine lact coolercontrol openrgb openrgb-plugin-effects-git wireplumber nvtop \
        mangohud goverlay pipewire-pulse libdvdcss gst-libav mpv-git ffmpeg pavucontrol \
        inputplumber lsfg-vk game-devices-udev udev-joystick-blacklist-git waydroid \
        # --- Shells & Prompts ---
        bash zsh fish bash-preexec bash-completion zsh-completions \
        atuin starship zoxide eza iotop-c smartmontools \
        # --- Development Base & CLI Tools ---
        base-devel meld procps-ng curl file git github-cli ripgrep fd fzf jq man-db man-pages \
        byobu openssh openssl wget paru just cosign \
        nano nano-syntax-highlighting micro vi nfs-utils btop konsave \
        unp unarj unrar unzip bzip2 p7zip unace cpio sharutils cabextract rpmextract xz \
        # --- Languages & IDEs ---
        nodejs npm rust gcc-go python-pip python-pipx \
        cargo-binstall cargo-update visual-studio-code-bin \
        # --- Networking & VPNs ---
        networkmanager networkmanager-openvpn wpa_supplicant iwd ethtool dnsutils \
        modemmanager usb_modeswitch nss-mdns bluez bluez-utils bluez-libs \
        openvpn wireguard-tools pptpclient helium-browser-bin \
        mullvad-vpn mullvad-vpn-daemon cloudflare-warp-bin tailscale \
        # --- Containers & Virtualization ---
        podman podman-compose docker docker-compose distrobox flatpak fwupd \
        # --- Sched-ext & Performance ---
        scx-scheds-git scx-tools-git scx-manager \
        ananicy-cpp cachyos-ananicy-rules gamescope-session-cachyos

# ==========================================
# POST-INSTALL CONFIGURATION
# ==========================================

# Master copy of custom executables. Overwrites defaults (like steamos-update).
COPY files/usr/bin /usr/bin
COPY files/usr/libexec /usr/libexec
RUN chmod -R 0755 /usr/bin /usr/libexec /usr/share/libalpm/scripts

# Install AUR packages from Stage 1
COPY --from=aur_builder /home/builduser/packages/ /tmp/aur-pkgs/
RUN --mount=type=cache,id=boppos-cache-${TARGET_CPU_MARCH},target=/usr/lib/sysimage/cache/pacman/pkg \
    pacman -U --noconfirm /tmp/aur-pkgs/*.pkg.tar.zst && \
    rm -rf /tmp/aur-pkgs

# Configure Flatpak
RUN flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# Fix suid permissions
RUN chmod 4755 \
    /usr/bin/sudo \
    /usr/bin/pkexec \
    /usr/bin/su \
    /usr/bin/unix_chkpwd \
    /usr/lib/polkit-1/polkit-agent-helper-1 \
    /usr/bin/passwd \
    /usr/bin/chsh \
    /usr/bin/chfn \
    /usr/bin/newgrp \
    /usr/bin/mount \
    /usr/bin/umount \
    /usr/bin/fusermount3

RUN systemd-sysusers

# Disable SELinux labeling in Podman
RUN mkdir -p /etc/containers/containers.conf.d && \
    printf '[containers]\nlabel = false\n' > /etc/containers/containers.conf.d/01-no-selinux.conf

# Enable required systemd services
RUN systemctl enable NetworkManager.service && \
    systemctl enable systemd-resolved.service && \
    systemctl enable dbus-broker.service && \
    systemctl enable bluetooth.service && \
    systemctl enable ModemManager.service && \
    systemctl enable ananicy-cpp.service && \
    systemctl enable scx_loader.service && \
    systemctl enable inputplumber.service && \
    systemctl enable brew-setup.service && \
    systemctl enable docker.service && \
    systemctl enable sddm.service && \
    systemctl enable usr-share-sddm-themes.mount && \
    systemctl enable var-opt.mount && \
    systemctl --global enable install-flatpaks.service

# Bootc / Dracut Fixes
RUN --mount=type=tmpfs,dst=/run \
    printf "systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n" | tee /usr/lib/dracut/dracut.conf.d/30-bootcrew-fix-bootc-module.conf && \
    printf 'reproducible=yes\nhostonly=no\ncompress=zstd\nadd_dracutmodules+=" ostree bootc "' | tee "/usr/lib/dracut/dracut.conf.d/30-bootcrew-bootc-container-build.conf" && \
    dracut --force "$(find /usr/lib/modules -maxdepth 1 -type d | grep -v -E '\.img$' | tail -n 1)/initramfs.img"

# Preserve /opt contents for OverlayFS
RUN mkdir -p /usr/lib/opt && \
    if [ -d /opt ] && [ "$(ls -A /opt)" ]; then \
        mv /opt/* /usr/lib/opt/ || true; \
    fi

# Final system setup and cleanup
RUN sed -i 's|^HOME=.*|HOME=/var/home|' "/etc/default/useradd" && \
    rm -rf /mnt /opt /boot /home /root /usr/local /srv /var /usr/lib/sysimage/log /usr/lib/sysimage/cache/pacman/pkg && \
    mkdir -p /sysroot /boot /usr/lib/ostree /var /run /tmp && \
    ln -s sysroot/ostree /ostree && ln -s var/roothome /root && ln -s var/srv /srv && ln -s var/opt /opt && ln -s var/mnt /mnt && ln -s var/home /home && ln -s ../var/usrlocal /usr/local && \
    echo "$(for dir in opt home srv mnt usrlocal ; do echo "d /var/$dir 0755 root root -" ; done)" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf" && \
    printf "d /var/roothome 0700 root root -\nd /run/media 0755 root root -" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf" && \
    printf '[composefs]\nenabled = yes\n[sysroot]\nreadonly = true\n' | tee "/usr/lib/ostree/prepare-root.conf"

RUN ln -sf ../usr/lib/os-release /etc/os-release
RUN ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime

# Add repository security keys
RUN mkdir -p /etc/pki/containers
COPY cosign.pub /etc/pki/containers/ripps818.pub

RUN rm -f /README.md
LABEL containers.bootc=1
