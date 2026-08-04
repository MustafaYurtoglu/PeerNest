# PeerNest App Icon Requirements

The existing artwork in `Assets.xcassets/AppIcon.appiconset` is preserved. The AppIcon catalog contains macOS slots for 16, 32, 128, 256, 512 points at 1× and 2×. Before release, export exact PNG dimensions for every slot from a square master (preferably at least 1024×1024), verify the icon's safe margin against the macOS icon mask, and assign each filename in `Contents.json` through Xcode.

Menu bar artwork should be a sharp monochrome template image with transparency and meaningful 1×/2× representations. Finder badges should use simple, high-contrast shapes that remain readable at small sizes. Add artwork only through the asset catalog; do not duplicate files in source folders.
