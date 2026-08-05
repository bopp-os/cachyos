#!/usr/bin/env python3
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("Error: Pillow is not installed. Please activate your .venv or install it using:")
    print("pip install Pillow")
    sys.exit(1)

def generate_icons(source_image_path):
    source_path = Path(source_image_path)
    if not source_path.exists():
        print(f"Error: Source image '{source_image_path}' not found.")
        sys.exit(1)
    
    if source_path.suffix.lower() != ".png":
        print("Warning: Source image does not have a .png extension.")

    # Get the project root directory (assuming the script is in ./scripts)
    script_dir = Path(__file__).parent.resolve()
    project_root = script_dir.parent
    base_icons_dir = project_root / "files" / "base" / "usr" / "share" / "icons" / "hicolor"

    # Standard freedesktop.org icon sizes
    sizes = [16, 22, 24, 32, 48, 64, 128, 256, 512]
    
    try:
        with Image.open(source_path) as img:
            # Ensure image is square
            if img.width != img.height:
                print(f"Warning: Source image is not square ({img.width}x{img.height}). It will be stretched.")

            for size in sizes:
                # Create directory if it doesn't exist
                target_dir = base_icons_dir / f"{size}x{size}" / "apps"
                target_dir.mkdir(parents=True, exist_ok=True)
                
                # Resize and save
                target_path = target_dir / source_path.name
                
                # Use high-quality resampling filter
                resized_img = img.resize((size, size), Image.Resampling.LANCZOS)
                resized_img.save(target_path, "PNG")
                print(f"✅ Generated {size}x{size} icon: {target_path.relative_to(project_root)}")
                
        print("\nIcon generation complete! You can now safely remove the original 800x800 PNG from the scalable directory.")
                
    except Exception as e:
        print(f"Error processing image: {e}")
        sys.exit(1)

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python scripts/generate-icons.py <path-to-source-png>")
        sys.exit(1)
        
    generate_icons(sys.argv[1])
