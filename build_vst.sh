#!/bin/bash
set -euo pipefail

# -------------------------------------------------
# Basic config
# -------------------------------------------------
PLUGIN_NAME="SyphonVST"

# Resolve paths relative to this script's directory
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

SYPHON_FRAMEWORK="$ROOT_DIR/Syphon.framework"
VST2_SDK_DIR="$ROOT_DIR/third_party/vst2sdk"

SYPHON_SDK_URL="https://github.com/Syphon/Syphon-Framework/releases/download/5/Syphon.SDK.5.zip"

die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# These will be set by ensure_vst2_sdk
VST2_INC_SRC=""
VST2_INC_IFACES=""

# -------------------------------------------------
# Ensure VST2 SDK (sysfce2/vst-2.4-sdk) exists
# -------------------------------------------------
ensure_vst2_sdk() {
  local src_dir="$VST2_SDK_DIR/vstsdk2.4/public.sdk/source/vst2.x"
  local ifaces_dir="$VST2_SDK_DIR/vstsdk2.4/pluginterfaces/vst2.x"

  if [[ -d "$src_dir" && -d "$ifaces_dir" ]]; then
    VST2_INC_SRC="$src_dir"
    VST2_INC_IFACES="$ifaces_dir"
    return
  fi

  echo "VST2 SDK not found locally, fetching sysfce2/vst-2.4-sdk…"
  mkdir -p "$VST2_SDK_DIR"

  if have git; then
    if [[ ! -d "$VST2_SDK_DIR/.git" ]]; then
      git clone --depth=1 https://github.com/sysfce2/vst-2.4-sdk.git "$VST2_SDK_DIR"
    else
      (cd "$VST2_SDK_DIR" && git fetch --depth=1 && git reset --hard origin/HEAD)
    fi
  else
    local tmpzip
    tmpzip="$(mktemp -t vst2sdk.zip.XXXXXX)"
    curl -L -o "$tmpzip" https://github.com/sysfce2/vst-2.4-sdk/archive/refs/heads/master.zip
    rm -rf "$VST2_SDK_DIR"
    mkdir -p "$VST2_SDK_DIR"
    unzip -q "$tmpzip" -d "$ROOT_DIR/third_party"
    # Move extracted repo contents into VST2_SDK_DIR
    local extracted
    extracted="$(/usr/bin/find "$ROOT_DIR/third_party" -maxdepth 1 -type d -name 'vst-2.4-sdk-*' -print -quit)"
    if [[ -n "$extracted" ]]; then
      mv "$extracted"/* "$VST2_SDK_DIR"/
      rmdir "$extracted" 2>/dev/null || true
    fi
    rm -f "$tmpzip"
  fi

  src_dir="$VST2_SDK_DIR/vstsdk2.4/public.sdk/source/vst2.x"
  ifaces_dir="$VST2_SDK_DIR/vstsdk2.4/pluginterfaces/vst2.x"

  [[ -d "$src_dir"    ]] || die "After download: VST2 src dir not found at: $src_dir"
  [[ -d "$ifaces_dir" ]] || die "After download: VST2 iface dir not found at: $ifaces_dir"

  VST2_INC_SRC="$src_dir"
  VST2_INC_IFACES="$ifaces_dir"
}

# -------------------------------------------------
# Ensure Syphon.framework from Syphon SDK 5
# -------------------------------------------------
ensure_syphon_framework() {
  if [[ -d "$SYPHON_FRAMEWORK" ]]; then
    return
  fi

  echo "Syphon.framework not found, downloading Syphon SDK 5…"

  local tmpzip tmpdir
  tmpzip="$(mktemp -t SyphonSDK5.zip.XXXXXX)"
  tmpdir="$(mktemp -d -t SyphonSDK5.XXXXXX)"

  curl -L -o "$tmpzip" "$SYPHON_SDK_URL"
  unzip -q "$tmpzip" -d "$tmpdir"

  # Find the first Syphon.framework in the extracted tree
  local fw_path
  fw_path="$(/usr/bin/find "$tmpdir" -type d -name 'Syphon.framework' -print -quit || true)"

  if [[ -z "$fw_path" ]]; then
    rm -rf "$tmpzip" "$tmpdir"
    die "Could not locate Syphon.framework inside Syphon.SDK.5.zip"
  fi

  rm -rf "$SYPHON_FRAMEWORK"
  mv "$fw_path" "$SYPHON_FRAMEWORK"

  rm -rf "$tmpzip" "$tmpdir"

  [[ -d "$SYPHON_FRAMEWORK" ]] || die "Failed to place Syphon.framework at $SYPHON_FRAMEWORK"
}

# -------------------------------------------------
# Parse flags
#   DEFAULT: instrument (SyphonVSTi.vst, synth)
#   --instrument  -> instrument (explicit)
#   --effect      -> effect (SyphonVST.vst)
#   --dest <dir>  -> install .vst into this directory instead of default
# -------------------------------------------------
IS_INSTRUMENT=1   # default is instrument
DEST_DIR="$HOME/Library/Audio/Plug-Ins/VST"

while (($#)); do
  case "$1" in
    --instrument)
      IS_INSTRUMENT=1
      shift
      ;;
    --effect)
      IS_INSTRUMENT=0
      shift
      ;;
    --dest|-d)
      shift
      [[ $# -gt 0 ]] || die "--dest requires a directory path"
      DEST_DIR="$1"
      shift
      ;;
    *)
      echo "Unknown arg: $1" >&2
      shift
      ;;
  esac
done

CPPDEFS_FLAGS=""
PLUGIN_VARIANT_NAME="$PLUGIN_NAME"
if [[ $IS_INSTRUMENT -eq 1 ]]; then
  CPPDEFS_FLAGS="-DSYPHON_VSTI=1"
  PLUGIN_VARIANT_NAME="${PLUGIN_NAME}i"   # SyphonVSTi.vst
else
  CPPDEFS_FLAGS=""                        # SyphonVST (effect)
  PLUGIN_VARIANT_NAME="${PLUGIN_NAME}"
fi

# -------------------------------------------------
# Xcode SDK (Mojave)
# -------------------------------------------------
if [[ -d "/Applications/Xcode_9.4.1.app" ]]; then
  XCODE="/Applications/Xcode_9.4.1.app"
else
  XCODE="/Applications/Xcode.app"
fi

if [[ -d "$XCODE/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.14.sdk" ]]; then
  SDKROOT="$XCODE/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.14.sdk"
else
  SDKROOT="$XCODE/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.13.sdk"
fi

# -------------------------------------------------
# Ensure SDKs / frameworks
# -------------------------------------------------
ensure_vst2_sdk
ensure_syphon_framework

# Validate VST2 sources
for f in audioeffect.cpp audioeffectx.cpp; do
  [[ -f "$VST2_INC_SRC/$f" ]] || die "Missing $VST2_INC_SRC/$f"
done

echo "Using VST2 headers (src):    $VST2_INC_SRC"
echo "Using VST2 headers (ifaces): $VST2_INC_IFACES"
echo "Using SDK:                   $SDKROOT"
echo "Using Syphon.framework:      $SYPHON_FRAMEWORK"
echo "Install destination:         $DEST_DIR"
if [[ $IS_INSTRUMENT -eq 1 ]]; then
  echo "Plugin type:                 INSTRUMENT (SyphonVSTi)"
else
  echo "Plugin type:                 EFFECT (SyphonVST)"
fi

# -------------------------------------------------
# Bundle layout
# -------------------------------------------------
mkdir -p "$DEST_DIR"

BUNDLE_DIR="$DEST_DIR/${PLUGIN_VARIANT_NAME}.vst"
MACOS_DIR="$BUNDLE_DIR/Contents/MacOS"
FW_DIR="$BUNDLE_DIR/Contents/Frameworks"
RES_DIR="$BUNDLE_DIR/Contents/Resources"

rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS_DIR" "$FW_DIR" "$RES_DIR"

# Info.plist
cat > "$BUNDLE_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>${PLUGIN_VARIANT_NAME}</string>
  <key>CFBundleIdentifier</key><string>com.pandela.${PLUGIN_VARIANT_NAME}</string>
  <key>CFBundleName</key><string>${PLUGIN_VARIANT_NAME}</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleSignature</key><string>VST!</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>10.9</string>
  <key>LSItemContentTypes</key><array>
    <string>com.steinberg.vst-plugin</string>
  </array>
</dict>
</plist>
EOF

echo -n "BNDL????" > "$BUNDLE_DIR/Contents/PkgInfo"

# -------------------------------------------------
# Build the binary
# -------------------------------------------------
clang++ "$ROOT_DIR/SyphonVST.mm" \
  "$VST2_INC_SRC/audioeffect.cpp" \
  "$VST2_INC_SRC/audioeffectx.cpp" \
  -std=c++14 -stdlib=libc++ -fobjc-arc -O2 \
  -Wno-writable-strings \
  -isysroot "$SDKROOT" -mmacosx-version-min=10.9 \
  -I"$VST2_INC_SRC" -I"$VST2_INC_IFACES" \
  -F"$ROOT_DIR" \
  -bundle -fvisibility=hidden -fvisibility-inlines-hidden \
  -Wl,-rpath,@loader_path/../Frameworks \
  $CPPDEFS_FLAGS \
  -o "$MACOS_DIR/${PLUGIN_VARIANT_NAME}" \
  -framework Cocoa -framework OpenGL -framework Syphon

# -------------------------------------------------
# Embed Syphon.framework & fix @rpath
# -------------------------------------------------
rsync -a --delete "$SYPHON_FRAMEWORK" "$FW_DIR/"
FW_BIN="$FW_DIR/Syphon.framework/Versions/A/Syphon"

if otool -D "$FW_BIN" | grep -q "^/"; then
  install_name_tool -id "@rpath/Syphon.framework/Versions/A/Syphon" "$FW_BIN"
fi

if ! otool -l "$MACOS_DIR/${PLUGIN_VARIANT_NAME}" | grep -A2 LC_RPATH | grep -q "@loader_path/../Frameworks"; then
  install_name_tool -add_rpath "@loader_path/../Frameworks" "$MACOS_DIR/${PLUGIN_VARIANT_NAME}"
fi

ABS_SYPHON=$(otool -L "$MACOS_DIR/${PLUGIN_VARIANT_NAME}" | awk '/Syphon\.framework\/Versions\/A\/Syphon/ {print $1}' | head -n1 || true)
if [[ -n "${ABS_SYPHON:-}" && "$ABS_SYPHON" != "@rpath/Syphon.framework/Versions/A/Syphon" ]]; then
  install_name_tool -change "$ABS_SYPHON" "@rpath/Syphon.framework/Versions/A/Syphon" "$MACOS_DIR/${PLUGIN_VARIANT_NAME}"
fi

strip -x "$MACOS_DIR/${PLUGIN_VARIANT_NAME}" || true
codesign -f -s - --deep "$BUNDLE_DIR" >/dev/null 2>&1 || true

echo "✅ Built ${PLUGIN_VARIANT_NAME}.vst → $BUNDLE_DIR"
