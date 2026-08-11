#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source_png="$project_dir/Assets/AppIcon-1024.png"
output_icns="$project_dir/Assets/AppIcon.icns"
mark_svg="$project_dir/Assets/OpenAIMark.svg"
mark_png="$project_dir/Assets/OpenAIMark.png"
iconset_dir="/tmp/dev.ruobin.OpenAIUsageBar.iconset"

if [[ ! -f "$source_png" ]]; then
  echo "Missing icon source: $source_png" >&2
  exit 1
fi

rm -rf "$iconset_dir"
mkdir -p "$iconset_dir"

for spec in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"
do
  size="${spec%% *}"
  name="${spec#* }"
  sips -z "$size" "$size" "$source_png" --out "$iconset_dir/$name" >/dev/null
done

iconutil -c icns "$iconset_dir" -o "$output_icns"
sips -z 256 256 -s format png "$mark_svg" --out "$mark_png" >/dev/null
echo "$output_icns"
