#!/usr/bin/env python3
import json
import sys
import argparse

def main():
    parser = argparse.ArgumentParser(description="Parse bootc status JSON")
    parser.add_argument("--staged-only", action="store_true", help="Only output the staged image digest/ref")
    args = parser.parse_args()

    try:
        input_data = sys.stdin.read()
        data = json.loads(input_data)
    except json.JSONDecodeError as e:
        if not args.staged_only:
            print(f"ERROR:parse:{e}")
        sys.exit(0)

    spec = data.get("spec", {}) or {}
    status = data.get("status", {}) or {}
    booted = status.get("booted") or {}
    staged = status.get("staged") or {}

    staged_img = staged.get("image") or {}
    staged_digest = staged_img.get("imageDigest") or staged_img.get("image", {}).get("image", "")

    if args.staged_only:
        print(staged_digest)
        return

    transport = spec.get("image", {}).get("transport", "registry")
    booted_img = booted.get("image") or {}
    current = booted_img.get("imageDigest") or booted_img.get("image", {}).get("image", "unknown")

    update_available = bool(staged_digest and staged_digest != current)

    print(f"UPDATE:{update_available}")
    print(f"CURRENT:{current}")
    print(f"STAGED:{staged_digest}")
    print(f"TRANSPORT:{transport}")
    print(f"IMAGE_REF:{booted_img.get('image', {}).get('image', '')}")

if __name__ == "__main__":
    main()