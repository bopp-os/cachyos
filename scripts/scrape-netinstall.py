#!/bin/env python
import urllib.request
import yaml

# The released ISO builds from cachyos-staging (cachyos-dev lags behind it; checked 2026-11-23)
URL = "https://raw.githubusercontent.com/CachyOS/cachyos-calamares/cachyos-staging/src/modules/netinstall/netinstall.yaml"

def print_group(group, indent=0):
    # Fallbacks in case a group is missing a name
    name = group.get('name', 'Unnamed Group')
    packages = group.get('packages', [])
    subgroups = group.get('subgroups', [])
    
    pad = " " * indent
    print(f"{pad}=== {name} ===")
    
    if packages:
        for pkg in packages:
            print(f"{pad}  - {pkg}")
    elif not subgroups:
        print(f"{pad}  (No packages listed)")
        
    # Calamares allows for nested subgroups, so we call this recursively
    for sub in subgroups:
        print()
        print_group(sub, indent + 4)

def scrape_packages():
    print(f"Fetching raw YAML from CachyOS repository...\n")
    try:
        req = urllib.request.urlopen(URL)
        # Parse the raw YAML directly into a Python dictionary/list
        data = yaml.safe_load(req)
    except Exception as e:
        print(f"Failed to fetch or parse the file: {e}")
        return

    # Depending on the Calamares version, groups are either at the root or under a 'groups' key
    if isinstance(data, dict):
        groups = data.get('groups', [])
    elif isinstance(data, list):
        groups = data
    else:
        print("Unrecognized YAML structure.")
        return
    
    if not groups:
        print("No groups found. The YAML structure might have changed.")
        return

    for group in groups:
        print_group(group)
        print("\n" + "-"*40 + "\n")

if __name__ == "__main__":
    scrape_packages()
