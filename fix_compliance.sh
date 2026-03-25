#!/bin/bash
# Fix P2 (exclude .md from bundle) and P3 (MACOSX_DEPLOYMENT_TARGET → IPHONEOS_DEPLOYMENT_TARGET)
# Run: chmod +x fix_compliance.sh && ./fix_compliance.sh

set -e

PROJ="/Users/pty11111/Documents/FreeDV/FreeDV.xcodeproj/project.pbxproj"
BACKUP="${PROJ}.backup2"

echo "=== FreeDV Compliance Fix Script ==="
echo ""

# Backup
cp "$PROJ" "$BACKUP"
echo "Backed up to: $BACKUP"

# P2: Add .md files to membership exceptions for FreeDV target
# Current: membershipExceptions = ( Info.plist, );
# Target:  membershipExceptions = ( ARCHITECTURE.md, Info.plist, RADE_iOS_Porting_Guide.md, dev.md, feature_inspiration.md, reporter_dev.md, );
sed -i '' '/1986D1FD2F70D98F00EFB5D1/{
N;N;N;
s|membershipExceptions = (\n\t\t\t\tInfo.plist,\n\t\t\t);|membershipExceptions = (\n\t\t\t\tARCHITECTURE.md,\n\t\t\t\tInfo.plist,\n\t\t\t\tRADE_iOS_Porting_Guide.md,\n\t\t\t\tdev.md,\n\t\t\t\tfeature_inspiration.md,\n\t\t\t\treporter_dev.md,\n\t\t\t);|
}' "$PROJ"
echo "P2: Added .md files to build exceptions"

# P3: Replace MACOSX_DEPLOYMENT_TARGET with IPHONEOS_DEPLOYMENT_TARGET at project level
sed -i '' 's/MACOSX_DEPLOYMENT_TARGET = 26\.2;/IPHONEOS_DEPLOYMENT_TARGET = 18.0;/g' "$PROJ"
echo "P3: Replaced MACOSX_DEPLOYMENT_TARGET with IPHONEOS_DEPLOYMENT_TARGET = 18.0"

echo ""
echo "Done! Please close and reopen Xcode to apply changes."
echo ""
echo "If something goes wrong, restore:"
echo "  cp '$BACKUP' '$PROJ'"
