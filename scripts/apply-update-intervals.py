#!/usr/bin/env python3
import sys
import os
import stat
import json
import subprocess
import errno


def main():
    verbose = False
    pos_args = []
    for arg in sys.argv[1:]:
        if arg in ("--verbose", "-v"):
            verbose = True
        else:
            pos_args.append(arg)

    json_file = pos_args[0] if len(pos_args) > 0 else ""
    rootfs = pos_args[1] if len(pos_args) > 1 else "/"
    pkg_file = pos_args[2] if len(pos_args) > 2 else ""

    if not json_file or not os.path.isfile(json_file):
        for candidate in (
            "/usr/share/boppos/package-intervals.json",
            "/tmp/package-intervals.json",
            "/tmp/scripts/package-intervals.json",
            "scripts/package-intervals.json",
        ):
            if os.path.isfile(candidate):
                json_file = candidate
                break

    if not json_file or not os.path.isfile(json_file):
        print(f"Error: JSON file '{json_file}' not found.", file=sys.stderr)
        sys.exit(1)

    try:
        with open(json_file, "r", encoding="utf-8") as f:
            intervals_db = json.load(f)
    except Exception as e:
        print(f"Error reading '{json_file}': {e}", file=sys.stderr)
        sys.exit(1)

    print(f"Applying user.update-interval xattrs to ROOTFS: {rootfs} using {json_file}")

    # Determine packages to process
    if pkg_file and os.path.isfile(pkg_file):
        try:
            with open(pkg_file, "r", encoding="utf-8") as f:
                pkgs = [line.strip() for line in f if line.strip()]
        except Exception as e:
            print(f"Error reading package file '{pkg_file}': {e}", file=sys.stderr)
            sys.exit(1)
    else:
        try:
            out = subprocess.check_output(["pacman", "-Qq"], text=True)
            pkgs = [line.strip() for line in out.splitlines() if line.strip()]
        except Exception as e:
            print(f"Error listing installed packages: {e}", file=sys.stderr)
            sys.exit(1)

    stats_intervals = {}
    stats_files = {}

    if not pkgs:
        print("No packages to process.")
    else:
        interval_suffixes = (
            "-yearly",
            "-quarterly",
            "-monthly",
            "-biweekly",
            "-weekly",
            "-daily",
        )

        # Process packages and apply xattrs
        for pkg in pkgs:
            pkg_entry = intervals_db.get(pkg)
            if isinstance(pkg_entry, dict) and "interval" in pkg_entry:
                interval = pkg_entry["interval"]
            else:
                interval = "weekly"
                if pkg not in intervals_db:
                    print(f"Warning: '{pkg}' not found in JSON, defaulting to weekly", file=sys.stderr)

            try:
                out = subprocess.check_output(["pacman", "-Qql", pkg], text=True, stderr=subprocess.DEVNULL)
                files = out.splitlines()
            except Exception:
                continue

            applied_count = 0
            skipped_count = 0
            for rel_file in files:
                if rel_file.endswith("/"):
                    continue

                full_path = os.path.join(rootfs, rel_file.lstrip("/"))

                try:
                    st = os.lstat(full_path)
                except OSError:
                    continue

                # Only tag regular files (skip symlinks and special files)
                if not stat.S_ISREG(st.st_mode):
                    continue

                # Skip re-tagging files already processed by real-time ALPM hook
                try:
                    os.getxattr(full_path, "user.update-interval", follow_symlinks=False)
                    skipped_count += 1
                    continue
                except OSError as e:
                    if e.errno not in (errno.ENODATA, 61):  # 61 is ENOATTR on macOS / Linux fallback
                        continue

                # Check if user.component exists and append interval suffix
                try:
                    comp_bytes = os.getxattr(full_path, "user.component", follow_symlinks=False)
                    comp = comp_bytes.decode(errors="ignore")
                    for s in interval_suffixes:
                        if comp.endswith(s):
                            comp = comp[:-len(s)]
                            break
                    comp_val = f"{comp}-{interval}"
                    os.setxattr(full_path, "user.component", comp_val.encode(), follow_symlinks=False)
                except OSError:
                    pass

                try:
                    os.setxattr(full_path, "user.update-interval", interval.encode(), follow_symlinks=False)
                    applied_count += 1
                except OSError:
                    pass

            stats_intervals[interval] = stats_intervals.get(interval, 0) + 1
            stats_files[interval] = stats_files.get(interval, 0) + applied_count
            if verbose:
                if applied_count > 0:
                    print(f"Applied user.update-interval={interval} to {pkg} ({applied_count} applied, {skipped_count} already tagged)")
                else:
                    print(f"Skipped {pkg} (all {skipped_count} files already tagged)")

        # Print summary table
        print("\n--- user.update-interval Summary ---")
        for intv in sorted(stats_intervals.keys()):
            print(f"{intv}: {stats_intervals[intv]} packages, {stats_files.get(intv, 0)} files newly tagged")

    # Tag compiled system caches and normalize timestamps for layer determinism
    print("Tagging compiled system caches as user.component=system-cache...")
    epoch = int(os.environ.get("SOURCE_DATE_EPOCH", "0"))
    cache_targets = [
        os.path.join(rootfs, "usr/share/glib-2.0/schemas/gschemas.compiled"),
        os.path.join(rootfs, "etc/ld.so.cache"),
    ]

    icons_dir = os.path.join(rootfs, "usr/share/icons")
    if os.path.isdir(icons_dir):
        for root, _, fnames in os.walk(icons_dir):
            if "icon-theme.cache" in fnames:
                cache_targets.append(os.path.join(root, "icon-theme.cache"))

    for cachefile in cache_targets:
        if os.path.isfile(cachefile) and not os.path.islink(cachefile):
            try:
                os.setxattr(cachefile, "user.component", b"system-cache", follow_symlinks=False)
                os.setxattr(cachefile, "user.update-interval", b"daily", follow_symlinks=False)
                # Clamp mtime to SOURCE_DATE_EPOCH for bit-for-bit reproducible layers
                os.utime(cachefile, (epoch, epoch), follow_symlinks=False)
            except OSError:
                pass

    # Sweep for remaining untagged regular files in /usr and /etc
    print("Sweeping for remaining untagged regular files in /usr and /etc...")
    sweep_dirs = [
        os.path.join(rootfs, "usr"),
        os.path.join(rootfs, "etc"),
    ]

    for sdir in sweep_dirs:
        if not os.path.isdir(sdir):
            continue
        for root, _, fnames in os.walk(sdir, followlinks=False):
            for fname in fnames:
                fpath = os.path.join(root, fname)
                try:
                    st = os.lstat(fpath)
                    if not stat.S_ISREG(st.st_mode):
                        continue
                    try:
                        os.getxattr(fpath, "user.component", follow_symlinks=False)
                    except OSError as e:
                        if e.errno in (errno.ENODATA, 61):
                            os.setxattr(fpath, "user.component", b"image-generated", follow_symlinks=False)
                            os.setxattr(fpath, "user.update-interval", b"weekly", follow_symlinks=False)
                except OSError:
                    pass

    print("Fallback component tagging complete.")


if __name__ == "__main__":
    main()
