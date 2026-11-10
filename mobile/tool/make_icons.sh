#!/bin/sh
# Resizes tool/icon-1024.png into the Android mipmaps and iOS AppIcon set (macOS `sips`).
# iOS icons must not contain an alpha channel, so they take a JPEG round trip.
set -e
cd "$(dirname "$0")/.."
SRC=tool/icon-1024.png
for pair in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
  sips -z "${pair#*:}" "${pair#*:}" "$SRC" --out "android/app/src/main/res/mipmap-${pair%%:*}/ic_launcher.png" >/dev/null
done
D=ios/Runner/Assets.xcassets/AppIcon.appiconset
for f in "$D"/Icon-App-*.png; do
  px=$(sips -g pixelWidth "$f" | awk '/pixelWidth/{print $2}')
  sips -z "$px" "$px" "$SRC" --out /tmp/_icon.png >/dev/null
  sips -s format jpeg /tmp/_icon.png --out /tmp/_icon.jpg >/dev/null
  sips -s format png /tmp/_icon.jpg --out "$f" >/dev/null
done
rm -f /tmp/_icon.png /tmp/_icon.jpg
echo done
