#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_name="OpenAI用量"
app_zip="$project_dir/outputs/OpenAI-Usage-macOS.zip"
staging_dir="$(mktemp -d /tmp/dev.ruobin.OpenAIUsageBar-dmg.XXXXXX)"
mount_point=""

cleanup() {
  if [[ -n "$mount_point" && -d "$mount_point" ]]; then
    hdiutil detach "$mount_point" -quiet || true
  fi
  rm -rf "$staging_dir"
}
trap cleanup EXIT

cd "$project_dir"
zsh scripts/build-app.sh

ditto -x -k "$app_zip" "$staging_dir"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$staging_dir/$app_name.app/Contents/Info.plist")"
output_dmg="$project_dir/outputs/OpenAI用量-$version-universal.dmg"
ln -s /Applications "$staging_dir/Applications"
cp "$project_dir/Assets/AppIcon.icns" "$staging_dir/.VolumeIcon.icns"

cat > "$staging_dir/安装说明.txt" <<'TEXT'
安装：将“OpenAI用量.app”拖到旁边的 Applications 文件夹。

系统要求：macOS 14 或更高版本，支持 Apple Silicon 和 Intel Mac。

本安装包未使用 Apple Developer ID 公证。首次打开如被 macOS 拦截，请在 Finder 中右键应用并选择“打开”。
TEXT

rm -f "$output_dmg"
hdiutil create \
  -volname "$app_name" \
  -srcfolder "$staging_dir" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$output_dmg"

hdiutil verify "$output_dmg"
attach_output="$(hdiutil attach -readonly -nobrowse -noautoopen "$output_dmg")"
mount_point="$(printf '%s\n' "$attach_output" | awk '$NF ~ /^\/Volumes\// {print $NF; exit}')"

if [[ -z "$mount_point" ]]; then
  echo "Unable to locate mounted DMG volume" >&2
  exit 1
fi

codesign --verify --deep --strict "$mount_point/$app_name.app"
lipo -verify_arch arm64 "$mount_point/$app_name.app/Contents/MacOS/OpenAIUsageBar"
lipo -verify_arch x86_64 "$mount_point/$app_name.app/Contents/MacOS/OpenAIUsageBar"
test -L "$mount_point/Applications"
test -f "$mount_point/安装说明.txt"

hdiutil detach "$mount_point" -quiet
mount_point=""

echo "$output_dmg"
