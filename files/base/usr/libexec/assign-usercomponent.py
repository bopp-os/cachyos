#!/usr/bin/env python3
import sys
import os
import stat
import json
import subprocess


def main():
    verbose = any(arg in ("--verbose", "-v") for arg in sys.argv[1:])

    # Locate package-intervals.json database
    json_file = ""
    for candidate in (
        "/tmp/package-intervals.json",
        "/tmp/scripts/package-intervals.json",
        "/usr/share/boppos/package-intervals.json",
        "scripts/package-intervals.json",
    ):
        if os.path.isfile(candidate):
            json_file = candidate
            break

    pkg_intervals = {}
    if json_file:
        try:
            with open(json_file, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict):
                    for k, v in data.items():
                        if isinstance(v, dict) and "interval" in v:
                            pkg_intervals[k] = v["interval"]
        except Exception:
            pass

    # Read target package names from stdin (provided by ALPM hook NeedsTargets)
    pkgs = [line.strip() for line in sys.stdin if line.strip()]
    if not pkgs:
        sys.exit(0)

    override_interval = os.environ.get("UPDATE_INTERVAL_TAG")
    override_comp = os.environ.get("COMPONENT_TAG")

    # Query pacman in batches to prevent exceeding ARG_MAX
    batch_size = 100
    for i in range(0, len(pkgs), batch_size):
        batch = pkgs[i : i + batch_size]
        try:
            proc = subprocess.Popen(
                ["pacman", "-Ql"] + batch,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
            )
        except Exception:
            continue

        for line in proc.stdout:
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            pkg = parts[0]
            filepath = parts[1].rstrip("\r\n")

            # Skip directory entries
            if filepath.endswith("/"):
                continue

            interval = override_interval or pkg_intervals.get(pkg, "weekly")
            base_comp = override_comp or pkg
            comp_val = f"{base_comp}-{interval}"

            try:
                # Target regular files only (skip symlinks and special files)
                st = os.lstat(filepath)
                if stat.S_ISREG(st.st_mode):
                    os.setxattr(filepath, "user.component", comp_val.encode(), follow_symlinks=False)
                    os.setxattr(filepath, "user.update-interval", interval.encode(), follow_symlinks=False)
                    if verbose:
                        print(f"Assigned user.component={comp_val} user.update-interval={interval} to {filepath}")
            except OSError:
                pass

        proc.wait()


if __name__ == "__main__":
    main()
