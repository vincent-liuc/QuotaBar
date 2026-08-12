#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
configuration="${1:-release}"
app_name="QuotaBar"
scratch_dir="/tmp/dev.ruobin.QuotaBar-build"
bundle_dir="$scratch_dir/$app_name.app"
contents_dir="$bundle_dir/Contents"
output_zip="$project_dir/outputs/QuotaBar-macOS.zip"
source_zip="$project_dir/outputs/QuotaBar-source.zip"
architectures=(--arch arm64 --arch x86_64)

cd "$project_dir"
zsh scripts/build-icon.sh
swift build --scratch-path "$scratch_dir" -c "$configuration" "${architectures[@]}"
binary_path="$(swift build --scratch-path "$scratch_dir" -c "$configuration" "${architectures[@]}" --show-bin-path)/QuotaBar"

rm -rf "$bundle_dir" "$project_dir/outputs/$app_name.app"
rm -f "$output_zip" "$source_zip"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$binary_path" "$contents_dir/MacOS/QuotaBar"
cp "$project_dir/Assets/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"
cp "$project_dir/Assets/QuotaMark.png" "$contents_dir/Resources/QuotaMark.png"

cat > "$contents_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>QuotaBar</string>
    <key>CFBundleIdentifier</key>
    <string>dev.ruobin.QuotaBar</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>QuotaBar</string>
    <key>CFBundleDisplayName</key>
    <string>QuotaBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.9.0</string>
    <key>CFBundleVersion</key>
    <string>13</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

xattr -cr "$bundle_dir"
codesign --force --deep --sign - "$bundle_dir"
codesign --verify --deep --strict "$bundle_dir"

ditto --norsrc --noextattr -c -k --keepParent "$bundle_dir" "$output_zip"
(
  cd "$project_dir"
  zip -qr "$source_zip" Package.swift README.md Assets Sources Tests scripts
)

echo "$output_zip"
