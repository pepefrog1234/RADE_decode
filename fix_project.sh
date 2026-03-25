#!/bin/bash
# Fix FreeDVWidgetExtensionExtension → FreeDVWidgetExtension in project.pbxproj
# Run this script AFTER closing Xcode, then reopen the project.

set -e

PROJ="/Users/pty11111/Documents/FreeDV/FreeDV.xcodeproj/project.pbxproj"
BACKUP="${PROJ}.backup"

echo "=== FreeDV Project Fix Script ==="
echo ""

# Note: Make sure Xcode is closed before running this script

# Backup
cp "$PROJ" "$BACKUP"
echo "✅ Backed up project file to: $BACKUP"

# 1. Rename FreeDVWidgetExtensionExtension → FreeDVWidgetExtension
sed -i '' 's/FreeDVWidgetExtensionExtension/FreeDVWidgetExtension/g' "$PROJ"
echo "✅ Renamed target: FreeDVWidgetExtensionExtension → FreeDVWidgetExtension"

# 2. Remove duplicate PBXFileSystemSynchronizedRootGroup (199C22B3)
#    Keep the original one (199C227F) and remove the duplicate
sed -i '' '/199C22B32F7347A200727B05 \/\* FreeDVWidgetExtension \*\/ = {/,/^[[:space:]]*};/d' "$PROJ"
echo "✅ Removed duplicate FreeDVWidgetExtension group"

# 3. Update the target to use original group (199C227F) instead of deleted one (199C22B3)
sed -i '' 's/199C22B32F7347A200727B05/199C227F2F72920B00727B05/g' "$PROJ"
echo "✅ Updated target group reference"

# 4. Add exceptions to original group so Info.plist is excluded from build
#    Replace the original group entry to include the exception
sed -i '' '/199C227F2F72920B00727B05 \/\* FreeDVWidgetExtension \*\/ = {/{
N
s/isa = PBXFileSystemSynchronizedRootGroup;/isa = PBXFileSystemSynchronizedRootGroup;\
			exceptions = (\
				199C22C52F7347A300727B05 \/* Exceptions for "FreeDVWidgetExtension" folder in "FreeDVWidgetExtension" target *\/,\
			);/
}' "$PROJ"

echo "✅ Added build exceptions to group"

# 5. Remove root-level FreeDVWidgetExtension.entitlements reference from main group children
sed -i '' '/199C22A92F7293CC00727B05 \/\* FreeDVWidgetExtension.entitlements \*\/,/d' "$PROJ"
echo "✅ Removed stale entitlements from group children"

# 6. Remove the PBXFileReference for root-level entitlements
sed -i '' '/199C22A92F7293CC00727B05 \/\* FreeDVWidgetExtension.entitlements \*\/ = {/d' "$PROJ"
echo "✅ Removed stale entitlements file reference"

# 7. Delete the root-level entitlements file
if [ -f "/Users/pty11111/Documents/FreeDV/FreeDVWidgetExtensionExtension.entitlements" ]; then
    rm "/Users/pty11111/Documents/FreeDV/FreeDVWidgetExtensionExtension.entitlements"
    echo "✅ Deleted FreeDVWidgetExtensionExtension.entitlements file"
fi

echo ""
echo "🎉 Done! Now open Xcode and the project should work correctly."
echo "   The widget extension target is now properly named 'FreeDVWidgetExtension'."
echo ""
echo "   If something goes wrong, restore from backup:"
echo "   cp '$BACKUP' '$PROJ'"
