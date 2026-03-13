#!/bin/bash

# Add Flathub remote if it doesn't exist
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# Install Flatpak applications
flatpak install --user -y flathub \
    net.mullvad.MullvadBrowser \
    com.calibre_ebook.calibre \
    org.kde.kate \
    org.kde.okular \
    org.inkscape.Inkscape \
    org.videolan.VLC \
    com.obsproject.Studio \
    dev.vencord.Vesktop \
    io.github.flattool.Warehouse \
    com.github.tchx84.Flatseal \
    com.bitwarden.desktop \
    com.vysp3r.ProtonPlus \
    org.kde.gwenview \
    org.kde.kcalc \
    io.github.kolunmi.Bazaar
