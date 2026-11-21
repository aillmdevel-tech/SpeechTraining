#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
out="${1:-$root/dist}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT
app="$build/SpeechTraining.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp macos/Info.plist "$app/Contents/Info.plist"
cp shared/CoachPrompt.txt "$app/Contents/Resources/CoachPrompt.txt"

for arch in arm64 x86_64; do
    swiftc -O -warnings-as-errors -target "${arch}-apple-macos14.0" macos/*.swift -o "$build/app-$arch"
done
for arch in arm64 amd64; do
    (cd gateway && CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" go build -trimpath -ldflags "-s -w" -o "$build/gateway-$arch" .)
done
lipo -create "$build/app-arm64" "$build/app-x86_64" -output "$app/Contents/MacOS/SpeechTraining"
lipo -create "$build/gateway-arm64" "$build/gateway-amd64" -output "$app/Contents/MacOS/speech-gateway"
chmod 755 "$app/Contents/MacOS/"*
codesign --force --sign - "$app/Contents/MacOS/speech-gateway"
codesign --force --sign - "$app"
codesign --verify --strict --deep "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/SpeechTraining-macos-universal.zip"
