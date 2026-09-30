# Draft comment for ValveSoftware/SteamVR-for-Linux#936

Paste everything below the line. The link works once this directory is on
`main`. Change it if the project moves to its own repository.

---

Thanks for the workaround above. It fixed SteamVR for me: native Steam with the
64-bit steamrt64 client, SteamVR 2.18.1 beta, Quest 3 via Steam Link,
RX 7900 XT (RADV), on a CachyOS-based distro.

The extra launcher service is lost every time Steam restarts, for example
after a client update. To avoid redoing the fix by hand, I wrapped it in a
small systemd user service:
https://github.com/bopp-os/cachyos/tree/main/steamvr-busname-fix

It watches the session bus. Whenever Steam's
`com.steampowered.PressureVessel.LaunchAlongsideSteam.Instance<N>` name is
present and the plain `com.steampowered.PressureVessel.LaunchAlongsideSteam`
name is missing, it runs the same fix again. It finds the runtime binaries
under `~/.local/share/Steam/steamrt64` rather than hardcoding the path. If
something already owns the plain name, it does nothing, so it should go quiet
once this is fixed. Install and uninstall are user-level, with no sudo. I
haven't tested it with Flatpak Steam.

It would be great if the Steam client registered the plain name itself, or if
`steam-runtime-launch-client --alongside-steam` fell back to the `Instance<N>`
names. Then none of this would be needed.
