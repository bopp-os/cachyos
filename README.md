# GuaraOS 🦜

A personal, immutable Arch-based Linux image built on top of [CachyOS](https://cachyos.org/) using [bootc](https://bootc-dev.github.io/).

This is a private fork maintained for my own machines. It is not intended as a general-purpose distribution and comes with no support or stability guarantees.

---

## Targets

| Flavor | Arch | Desktop | Session | Machine |
|---|---|---|---|---|
| `guaraos-gnome` | `znver4` | GNOME | GNOME (GDM) | Daily driver (AMD Ryzen 7000+) |
| `guaraos-gamestation` | `znver4` | KDE Plasma | Gamescope → Plasma (plasmalogin) | Gaming rig (AMD Ryzen 7000+) |
| `guaraos-gamestation` | `v3` | KDE Plasma | Gamescope → Plasma (plasmalogin) | Gaming rig (generic x86-64) |

---

## Build

Requires `just` and `podman`.

```bash
# Primary — znver4 / GNOME
just build znver4 base
just build znver4 gnome

# Secondary — znver4 / Gamestation (AMD gaming rig)
just build znver4 base
just build znver4 gamestation

# Secondary — v3 / Gamestation (generic gaming rig)
just build v3 base
just build v3 gamestation
```

## Switch

To rebase a running `bootc` system to this image:

```bash
sudo bootc switch ghcr.io/guara92/guaraos-gnome:znver4
# or
sudo bootc switch ghcr.io/guara92/guaraos-gamestation:znver4
# or
sudo bootc switch ghcr.io/guara92/guaraos-gamestation:v3
```

> After switching from a Fedora-based OS run `sudo guara-migrate` on first boot to set up your systemd-homed account.

## Update

Once running:

```bash
guaraos-update
```

---

## User Management

GuaraOS uses [`systemd-homed`](https://systemd.io/HOME_DIRECTORY/) for user accounts. Home directories are self-contained and portable across upgrades.

When migrating from Bazzite or another Fedora-based OS, run:

```bash
sudo guara-migrate
```

This creates a homed user account, migrates preserved data (SSH keys, browser profiles, game libraries) from the old home, and resets shell configs from scratch.

---

## Credits

GuaraOS would not exist without the work of these projects:

- **[CachyOS](https://github.com/CachyOS)** — the Arch-based foundation, performance-tuned kernels, and repositories this image is built on
- **[BoppOS](https://github.com/bopp-os)** by [ripps818](https://github.com/ripps818) — the direct upstream fork this repo is derived from; most of the Containerfile architecture, build system, and custom scripts originate there
- **[cachyos-deckify-bootc](https://github.com/lumaeris/cachyos-deckify-bootc)** by [lumaeris](https://github.com/lumaeris) — the original project BoppOS forked from
- **[Bootcrew / mono](https://github.com/bootcrew/mono)** — shared bootc setup scripts used during the image build
- **[bootc](https://github.com/containers/bootc)** — the atomic image management layer that makes all of this possible

---

## License

Apache-2.0 — inherited from upstream. See [LICENSE](LICENSE).