# steamvr-busname-fix

Workaround for **SteamVR Fail (-201)** on Linux: vrcompositor never starts
with Steam's 64-bit (`steamrt64`) client.
Upstream bug: [ValveSoftware/SteamVR-for-Linux#936](https://github.com/ValveSoftware/SteamVR-for-Linux/issues/936).

This is a small systemd user service. It registers the D-Bus name SteamVR
looks for, `com.steampowered.PressureVessel.LaunchAlongsideSteam`, and
registers it again every time Steam restarts.

> [!IMPORTANT]
> **Remove this once Valve fixes #936.** It's a stopgap. See
> [When Valve fixes #936](#when-valve-fixes-936).

## Symptoms

SteamVR shows **SteamVR Fail (-201)** after about 20 seconds, and the
compositor never starts. Steam's log directory (usually
`~/.local/share/Steam/logs/`) has these lines:

`vrstartup-linux.txt`:

```
steam-runtime-launch-client[...]: E: Unable to connect to any of the specified bus names (is steam-runtime-launcher-service running?)
```

`vrserver.txt` (the exact number of seconds varies):

```
timeout - vrcompositor process is not running.
Failed Watchdog timeout in thread Connection after 20.x seconds. Aborting.
```

`vrdashboard.txt`:

```
VR_Init failed with VRInitError_IPC_CompositorInitFailed
```

To confirm, run this while Steam is running:

```sh
busctl --user list | grep LaunchAlongsideSteam
```

If the only match is `com.steampowered.PressureVessel.LaunchAlongsideSteam.Instance<N>`
and the plain `com.steampowered.PressureVessel.LaunchAlongsideSteam` is
missing, you're hitting this bug.

## Root cause

Steam's newer 64-bit client (the one under `~/.local/share/Steam/steamrt64`)
runs a launcher service that starts programs alongside Steam, in the Steam
client's runtime environment. It registers that service on the D-Bus session
bus only as `com.steampowered.PressureVessel.LaunchAlongsideSteam.Instance<N>`.
In `ps`, that service appears as `x86_64-linux-gnu-srt-launcher-service`, with
its process name truncated to `x86_64-linux-gn`, so
`pgrep steam-runtime-launcher-service` won't find it.

SteamVR's vrserver launches vrcompositor with
`steam-runtime-launch-client --alongside-steam`, which looks for the plain name
`com.steampowered.PressureVessel.LaunchAlongsideSteam`. Nothing owns that name,
so the compositor never starts. vrserver's watchdog aborts after ~20 seconds,
and SteamVR reports -201.

The fix this is based on was posted in
[#936](https://github.com/ValveSoftware/SteamVR-for-Linux/issues/936), and
credit goes to the people in that thread. It asks Steam's instance service to
start a second launcher service that claims the plain name. That works until
Steam restarts (for example, after a client update), and then SteamVR breaks
again. This service redoes the fix automatically.

<details>
<summary>One-shot version, to try it without installing anything</summary>

Run this while Steam is running. It lasts until Steam restarts.

```sh
PV=~/.local/share/Steam/steamrt64/pv-runtime/steam-runtime-steamrt/pressure-vessel
INST=$(busctl --user list --no-legend | grep -o 'com\.steampowered\.PressureVessel\.LaunchAlongsideSteam\.Instance[0-9A-Za-z_-]*' | head -n 1)
"$PV/bin/steam-runtime-launch-client" --bus-name="$INST" -- \
    "$PV/libexec/steam-runtime-tools-0/x86_64-linux-gnu-srt-launcher-service" \
    --alongside-steam --bus-name=com.steampowered.PressureVessel.LaunchAlongsideSteam &
```

</details>

## What the service does

Every 5 seconds, `steamvr-busname-fix`:

1. Does nothing if something already owns
   `com.steampowered.PressureVessel.LaunchAlongsideSteam`.
2. Does nothing if Steam isn't running, meaning no
   `…LaunchAlongsideSteam.Instance<N>` name is on the bus.
3. Finds `steam-runtime-launch-client` and
   `x86_64-linux-gnu-srt-launcher-service`. It checks the known path under
   `~/.local/share/Steam/steamrt64` first. If that fails, it searches the
   `steamrt64` directory of `~/.local/share/Steam`, `~/.steam/root`,
   `~/.steam/steam` and `~/.steam/debian-installation`. It caches the result
   and searches again if the files disappear.
4. Runs the one-shot fix through Steam's `Instance<N>` service and logs whether
   the plain name was registered. After a failure it waits 15 s before
   retrying, doubling the wait up to 5 minutes. The wait resets after a success
   or when Steam restarts.

Stopping the service also stops the launch client it started.

## Install

You need native Steam with the 64-bit client, a systemd user session, and
bash. No sudo is needed.

```sh
git clone --depth 1 https://github.com/bopp-os/cachyos.git
cd cachyos/steamvr-busname-fix
./install.sh
```

The installer puts `steamvr-busname-fix` in `~/.local/bin` and
`steamvr-busname-fix.service` in `~/.config/systemd/user`. It then runs
`systemctl --user daemon-reload`, enables the service, and (re)starts it.
Running it again upgrades in place, including over a manual install that uses
the same file names.

## Verify

Start Steam, wait a few seconds, then run:

```sh
busctl --user list | grep LaunchAlongsideSteam
```

Both names should be listed:

```
com.steampowered.PressureVessel.LaunchAlongsideSteam              …
com.steampowered.PressureVessel.LaunchAlongsideSteam.Instance<N>  …
```

Then check the service log:

```sh
journalctl --user -u steamvr-busname-fix
```

It should say "registered":

```
steamvr-busname-fix[…]: registered com.steampowered.PressureVessel.LaunchAlongsideSteam via com.steampowered.PressureVessel.LaunchAlongsideSteam.Instance<N>
```

Now start SteamVR. To watch the service re-register after a Steam restart, run
`journalctl --user -u steamvr-busname-fix -f`.

Other messages:

| Message | Meaning |
| --- | --- |
| `… already has an owner; nothing to do` | Something else registered the plain name, possibly Steam itself after a fix. |
| `can't find steam-runtime-launch-client and …` | The runtime binaries weren't found. The message lists where it looked, and it keeps checking every 30 s. |
| `registration failed: …; retrying in Ns` | The launch client's own error is logged just above this line. |
| `… went away (Steam exited or restarted)` | Normal. The name is registered again when Steam is back. |

## Uninstall

```sh
./uninstall.sh
```

This stops and disables the service, removes both files, and reloads systemd.
If `busctl --user list | grep LaunchAlongsideSteam` still shows the plain name
afterwards, it goes away the next time Steam restarts.

## When Valve fixes #936

Remove this service once Valve fixes
[#936](https://github.com/ValveSoftware/SteamVR-for-Linux/issues/936). Until
you do, it's harmless: if Steam registers the plain name itself, the service
logs `already has an owner; nothing to do` and stays idle.

To check whether a Steam update has fixed the bug:

```sh
systemctl --user stop steamvr-busname-fix
# restart Steam, then:
busctl --user list | grep LaunchAlongsideSteam
```

If the plain name shows up without the service running, the bug is fixed and
you can run `./uninstall.sh`. Otherwise, run
`systemctl --user start steamvr-busname-fix`.

## Tested configuration

- Native (non-Flatpak) Steam with the 64-bit `steamrt64` client
- SteamVR 2.18.1 beta
- Meta Quest 3 via Steam Link
- AMD Radeon RX 7900 XT (RADV)
- CachyOS-based distro

This has **not been tested with Flatpak Steam**. Flatpak Steam uses a
different D-Bus setup and install location, and the script doesn't look for
it.

## Related Linux + Quest Steam Link gotchas

### SteamVR setup hangs trying to setcap vrcompositor-launcher

SteamVR's setup tries to give `vrcompositor-launcher` the `CAP_SYS_NICE`
capability through a zenity password prompt. The zenity in Steam's runtime
fails to start because `libgtk-x11-2.0` is missing, so the prompt never
appears and SteamVR can hang. Set the capability yourself:

```sh
sudo setcap CAP_SYS_NICE=eip ~/.local/share/Steam/steamapps/common/SteamVR/bin/linux64/vrcompositor-launcher
getcap ~/.local/share/Steam/steamapps/common/SteamVR/bin/linux64/vrcompositor-launcher
```

- Run this again after every SteamVR update, because updates replace the file.
- If SteamVR is in a different Steam library, adjust the path.
- File capabilities are ignored on filesystems mounted `nosuid`. Check the
  mount options with
  `findmnt -no OPTIONS -T ~/.local/share/Steam/steamapps/common/SteamVR`.

### The dashboard's Desktop tab crashes Steam, and SteamVR with it

Opening the Desktop tab in the SteamVR dashboard can crash the Steam client,
which takes SteamVR down too
([SteamVR-for-Linux#963](https://github.com/ValveSoftware/SteamVR-for-Linux/issues/963)).
The workaround is to switch back to the old desktop view by setting
`"dashboard": {"useNewDesktop": false}` in
`~/.local/share/Steam/config/steamvr.vrsettings`. Close SteamVR before editing
the file:

```sh
f=~/.local/share/Steam/config/steamvr.vrsettings
cp "$f" "$f.bak"
jq '.dashboard.useNewDesktop = false' "$f.bak" > "$f"
```

On Wayland, the old desktop view may be blank.
[wlx-overlay-s](https://github.com/galister/wlx-overlay-s) is an alternative
way to see your desktop in VR.

### Implicit Vulkan layers (e.g. lsfg-vk) load into SteamVR

Implicit Vulkan layers load into every Vulkan program, including SteamVR's
processes. To keep a layer such as lsfg-vk out, set SteamVR's launch options
(Library → SteamVR → Properties → Launch Options) to:

```
VK_LOADER_LAYERS_DISABLE='*lsfg*' %command%
```

This needs Vulkan loader 1.3.234 or newer. Installed implicit layers are listed
in `/usr/share/vulkan/implicit_layer.d/`, `/etc/vulkan/implicit_layer.d/` and
`~/.local/share/vulkan/implicit_layer.d/`.

vrcompositor is started through Steam's launcher service (see
[Root cause](#root-cause)), so it may not see SteamVR's launch options. If a
layer still loads there, look up the variable named by `disable_environment`
in the layer's JSON manifest, and set it in the environment Steam starts from.

### VPN kill switches block Steam Link

A VPN kill switch (Mullvad's, for example) can block Steam Link from
discovering the headset. It can also block traffic on the network interface
the Quest creates when USB-tethered. Allow LAN traffic:

```sh
mullvad lan set allow
```

Don't try to split-tunnel SteamVR instead. Discovery is done by the Steam
client, and vrcompositor is spawned outside SteamVR's process tree.

## License

This directory is MIT-licensed; see [LICENSE](LICENSE). The rest of the
bopp-os/cachyos repository has its own license.
