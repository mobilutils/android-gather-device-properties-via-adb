#!/usr/bin/env bash
#
# gather-deviceproperties.sh
# Extracts device properties from an Android device via ADB and produces
# a .properties file suitable for use with Aurora Store / gplaydl device profiles.
#
# Output: profiles/<YYYYMMDD>_<MODEL>.properties
#
# Usage:
#   ./gather-deviceproperties.sh              # interactive: prompts for device & name
#   ./gather-deviceproperties.sh -s <serial>  # target a specific device by serial
#   ./gather-deviceproperties.sh -n "<name>"  # set UserReadableName without prompting
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES_DIR="${SCRIPT_DIR}/profiles"
OUTPUT_FILE=""
DEVICE_SERIAL=""
READABLE_NAME=""
TEMP_DIR=""

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
  echo "Usage: $0 [-s <serial>] [-n <readable-name>]"
  echo ""
  echo "Options:"
  echo "   -s <serial>   Target device by serial (default: auto-select)"
  echo "   -n <name>     Set UserReadableName without prompting"
  echo ""
  echo "Output: profiles/<YYYYMMDD>_<MODEL>.properties"
  exit 1
}

while getopts "s:n:h" opt; do
  case "${opt}" in
    s) DEVICE_SERIAL="${OPTARG}" ;;
    n) READABLE_NAME="${OPTARG}" ;;
    h) usage ;;
    *) usage ;;
  esac
done
# Helpers
# ---------------------------------------------------------------------------
die() { echo "ERROR: $*" >&2; cleanup; exit 1; }
warn() { echo "WARNING: $*" >&2; }
info() { echo "INFO: $*"; }

# Portable extract helpers — pure sed, no ggrep required.
# Each replaces a `grep -oP 'KEY=\K[0-9]+' | head -1` pattern.
_extract_val() {
  echo "$1" | sed -n "s/.*${2}\([0-9][0-9]*\).*/\1/p" | head -1
}
_extract_val_ws() {
  echo "$1" | sed -n "s/.*${2}[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p" | head -1
}
_extract_val_colon() {
  echo "$1" | sed -n "s/.*${2}:[[:space:]]*\([0-9][0-9]*\).*/\1/p" | head -1
}
_extract_str_colon() {
  echo "$1" | sed -n "s/.*${2}:[[:space:]]*\([^[:space:]]*\).*/\1/p" | head -1
}

_extract_str() {
  echo "$1" | sed -n "s/.*${2}\([^ ]*\).*/\1/p" | head -1
}
_extract_str_ws() {
  echo "$1" | sed -n "s/.*${2}[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p" | head -1
}


cleanup() {
  if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
    rm -rf "${TEMP_DIR}"
  fi
}
trap cleanup EXIT INT TERM

ensure_adb() {
  if ! command -v adb &>/dev/null; then
    die "adb not found in PATH. Install Android Platform Tools or add to PATH."
  fi
}

# Run adb, handling multi-device selection. Accepts optional -s flag.
adb_shell() {
  if [[ -n "${DEVICE_SERIAL}" ]]; then
    adb -s "${DEVICE_SERIAL}" shell "$@"
  else
    adb shell "$@"
  fi
}

# Parse a getprop key=value line, returning the value.
get_prop() {
  local key="$1"
  local prop_file="$2"
  local val
    # Format is [key]: [value]
  val=$(grep -m1 "^\[${key}\]:" "${prop_file}" 2>/dev/null | sed "s/^\[${key}\]: \[//;s/\]$//;s/[[:space:]]*$//")
  echo "${val:-}"
}

# Extract versionCode from dumpsys package output.
extract_version_code() {
  local output="$1"
  local vc
  vc=$(_extract_val "${output}" 'versionCode=')
  echo "${vc:-0}"
}

# Extract versionName from dumpsys package output.
extract_version_name() {
  local output="$1"
  local vn
  vn=$(_extract_str "${output}" 'versionName=')
  echo "${vn:-unknown}"
}

# Extract features from dumpsys package output.
# Features appear as:
#   Features:
#     android.hardware.feature.foo
#     com.samsung.feature.bar version=123
#   Returns comma-separated list with version suffixes stripped.
extract_features() {
  local output="$1"
    # Extract everything between "Features:" and the next major section (capital letter at column 0)
  echo "${output}" | sed -n '/^Features:/,/^Activity Resolver Table:/p' | \
    grep '^  [a-z]' | \
    sed 's/^  //' | \
    sed 's/ version=[0-9]*$//' | \
    tr '\n' ',' | \
    sed 's/,$//'
}

# Extract shared libraries from dumpsys package output.
# Libraries appear as:
#   Libraries:
#     libfoo.so ->   (so) libfoo.so
#     android.test.base ->   (jar) /system/framework/android.test.base.jar
# Returns comma-separated list of library names (left side of ->).
extract_shared_libraries() {
  local output="$1"
     # Try the Libraries section
  local libs
  libs=$(echo "${output}" | sed -n '/^Libraries:/,/^$/p' | \
    grep '^  [a-zA-Z]' | \
    sed 's/^  //' | \
    sed 's/ ->.*//' | \
    tr '\n' ',' | \
    sed 's/,$//' || true)

  if [[ -n "${libs}" ]]; then
    echo "${libs}"
    return
  fi

     # Fallback: no libraries section (older Android versions)
  echo ""
}



# Extract GL version and extensions from dumpsys surface_flinger output.
# GL version is often in the GPU renderer string.
# GL extensions appear as space-separated tokens (e.g. "GL_EXT_debug_marker GL_ARM_rgba8 …").
# Returns: "<GL_VERSION> <comma-separated-GL-extensions>"
extract_gl_info() {
  local gl_output="$1"
  local gl_version gl_extensions

  # GL version — try multiple key=value patterns
  gl_version=$(_extract_val_ws "${gl_output}" 'GL_VERSION')
  if [[ -z "${gl_version}" ]]; then
    gl_version=$(_extract_val_colon "${gl_output}" 'GL_VERSION')
  fi

  # GL extensions — extract all GL_* tokens (space-separated on one or more lines),
  # then join them with commas.
  gl_extensions=$(echo "${gl_output}" | grep -oE '\bGL_[A-Za-z0-9_]+')
  if [[ -n "${gl_extensions}" ]]; then
    gl_extensions=$(echo "${gl_extensions}" | paste -sd ',' -)
  fi

  echo "${gl_version:-196610} ${gl_extensions:-}"
}


# Radio / baseband version
extract_radio() {
  local prop_file="$1"
  local baseband
     # Try the standard baseband property first
  baseband=$(get_prop "gsm.version.baseband" "${prop_file}")
  if [[ -z "${baseband}" ]]; then
    baseband=$(get_prop "ro.baseband" "${prop_file}")
  fi
  if [[ -z "${baseband}" ]]; then
     # Fall back to build display ID (often contains baseband info)
    baseband=$(get_prop "ro.build.display.id" "${prop_file}")
  fi
  if [[ -z "${baseband}" ]]; then
    baseband=$(get_prop "ro.build.version.release" "${prop_file}")
  fi
     # Only use first 100 chars to avoid duplicates from repeated grep matches
  baseband=$(echo "${baseband:-unknown}" | cut -d"," -f1)
  echo "${baseband:-unknown},${baseband:-unknown}"
}
# Extract screen metrics from dumpsys display output.
extract_screen_metrics() {
  local display_output="$1"
  local width height density

      # Width - try multiple patterns for different Android versions
  width=$(_extract_val "${display_output}" 'deviceWidth=')
  if [[ -z "${width}" ]]; then
    width=$(_extract_val "${display_output}" 'width=')
  fi
      # Height
  height=$(_extract_val "${display_output}" 'deviceHeight=')
  if [[ -z "${height}" ]]; then
    height=$(_extract_val "${display_output}" 'height=')
  fi
      # Density (dpi) - Android 14+ format: "density 450"
  density=$(_extract_val "${display_output}" 'density ')
  if [[ -z "${density}" ]]; then
    density=$(_extract_val "${display_output}" 'mDensity=')
  fi

  echo "${width:-1080} ${height:-2340} ${density:-440}"
}





# Determine the screen layout value (0=small, 1=normal, 2=large, 3=xlarge)
# based on diagonal size in inches.
calc_screen_layout() {
  local width="$1" height="$2" density="$3"

       # Approximate diagonal size from pixels and density:
       # diagonal_inches ≈ sqrt(width² + height²) / density * 160
       # We can't compute sqrt in bash, so approximate with area/density²
  local area=$(( width * height ))
  local density_sq=$(( density * density ))
       # For a 6" phone at 440dpi: area ≈ 1080*2340 = 2,527,200, density² ≈ 193,600
       # ratio ≈ 13 → this is roughly "normal" (1)
       # For a 7"+ tablet: area > 3M, ratio > 15 → "large" (2)
  local ratio=$(( area / density_sq ))
  if (( ratio > 15 )); then
    echo "2"        # large (tablets, phablets)
  elif (( ratio > 12 )); then
    echo "2"        # large (big phones)
  elif (( ratio > 10 )); then
    echo "1"        # normal (most phones)
  else
    echo "1"        # normal
  fi
}
# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
ensure_adb

# Create temp directory for intermediate files
TEMP_DIR=$(mktemp -d)

# --- Device selection -------------------------------------------------------
if [[ -z "${DEVICE_SERIAL}" ]]; then
  _devices=$(adb devices 2>/dev/null | tail -n +2 | grep -v '^*' || true)
  if [[ -z "${_devices}" ]]; then
    die "No devices connected. Connect a device via USB (or start an emulator) and try again."
  fi

  _device_count=$(echo "${_devices}" | wc -l)

  if (( _device_count == 1 )); then
    DEVICE_SERIAL=$(echo "${_devices}" | head -1 | awk '{print $1}')
    info "Found single device: ${DEVICE_SERIAL}"
  else
    echo "Multiple devices found:"
    echo "${_devices}" | nl -w1 -s') '
    read -rp "Enter device number: " selected_device
    if [[ -z "${selected_device}" ]]; then
      die "No device selected."
    fi
    DEVICE_SERIAL=$(echo "${_devices}" | sed -n "${selected_device}p" | awk '{print $1}')
    if [[ -z "${DEVICE_SERIAL}" ]]; then
      die "Invalid device selection."
    fi
    info "Selected device: ${DEVICE_SERIAL}"
  fi
fi

# Verify the device is accessible
if ! adb -s "${DEVICE_SERIAL}" shell echo "ok" &>/dev/null; then
  die "Cannot communicate with device ${DEVICE_SERIAL}. Ensure USB debugging is enabled."
fi

# --- Collect properties ------------------------------------------------------
info "Collecting device properties..."

# 1. Raw getprop output
adb_shell getprop > "${TEMP_DIR}/getprop.txt" || die "Failed to get properties from device."

# 2. dumpsys package (for features, shared libs, and specific packages)
adb_shell "dumpsys package" > "${TEMP_DIR}/dumpsys_pkg.txt" || warn "Failed to get dumpsys package output."

# 3. dumpsys display (screen metrics)
adb_shell "dumpsys display" > "${TEMP_DIR}/dumpsys_display.txt" || warn "Failed to get dumpsys display output."

# 4. dumpsys SurfaceFlinger / surface_flinger (GL info — API 19+ uses SurfaceFlinger, older uses surface_flinger)
adb_shell "dumpsys SurfaceFlinger" > "${TEMP_DIR}/dumpsys_surface.txt" 2>&1 || adb_shell "dumpsys surface_flinger" > "${TEMP_DIR}/dumpsys_surface.txt" 2>&1 || warn "Failed to get dumpsys surface_flinger output."

# --- Extract values ----------------------------------------------------------
info "Parsing properties..."

PROP_FILE="${TEMP_DIR}/getprop.txt"

# Build properties
BUILD_BOOTLOADER=$(get_prop "ro.bootloader" "${PROP_FILE}")
BUILD_BRAND=$(get_prop "ro.product.brand" "${PROP_FILE}")
BUILD_DEVICE=$(get_prop "ro.product.device" "${PROP_FILE}")
BUILD_FINGERPRINT=$(get_prop "ro.build.fingerprint" "${PROP_FILE}")
BUILD_HARDWARE=$(get_prop "ro.hardware" "${PROP_FILE}")
BUILD_ID=$(get_prop "ro.build.id" "${PROP_FILE}")
BUILD_MANUFACTURER=$(get_prop "ro.product.manufacturer" "${PROP_FILE}")
BUILD_MODEL=$(get_prop "ro.product.model" "${PROP_FILE}")
BUILD_PRODUCT=$(get_prop "ro.product.name" "${PROP_FILE}")
BUILD_VERSION_RELEASE=$(get_prop "ro.build.version.release" "${PROP_FILE}")
BUILD_VERSION_SDK=$(get_prop "ro.build.version.sdk" "${PROP_FILE}")

# Device identifiers
CELL_OPERATOR=$(get_prop "gsm.operator.alpha" "${PROP_FILE}")
if [[ -z "${CELL_OPERATOR}" || "${CELL_OPERATOR}" == "," ]]; then
        # Try numeric operator code (e.g. 20820 for France)
  CELL_OPERATOR=$(get_prop "gsm.operator.numeric" "${PROP_FILE}")
  CELL_OPERATOR=$(echo "${CELL_OPERATOR}" | cut -d"," -f1 | tr -d " ")
fi
if [[ -z "${CELL_OPERATOR}" ]]; then
  CELL_OPERATOR="310260"      # default (US T-Mobile)
fi
SIM_OPERATOR=$(get_prop "gsm.sim.operator.alpha" "${PROP_FILE}")
if [[ -z "${SIM_OPERATOR}" || "${SIM_OPERATOR}" == "," ]]; then
  SIM_OPERATOR="${CELL_OPERATOR}"
fi

# Locales
DEVICE_LOCALE=$(get_prop "ro.product.locale" "${PROP_FILE}")
if [[ -z "${DEVICE_LOCALE}" ]]; then
  LOCALES="en,de,fr,es,it,ja,ko,zh_CN,zh_TW,pt_BR,ar,hi,in,tr,ru,pl,sv,nl,fi,da,cs,hu,ro,sk"
else
        # Handle both _ and - as separator (e.g. en_GB or en-GB)
  LOCALE_LANG=$(echo "${DEVICE_LOCALE}" | sed 's/[-_].*//')
  LOCALE_COUNTRY=$(echo "${DEVICE_LOCALE}" | sed 's/^[^-_]*[-_]//')

        # Build a list starting with full locale, then lang-only
  LOCALES="${DEVICE_LOCALE}"
  if [[ -n "${LOCALE_COUNTRY}" && "${LOCALE_COUNTRY}" != "${DEVICE_LOCALE}" ]]; then
    LOCALES="${DEVICE_LOCALE},${LOCALE_LANG}"
  else
    LOCALES="${LOCALE_LANG}"
  fi

        # Add common locales, deduplicated
  LOCALES="${LOCALES},de,fr,es,it,ja,ko,zh_CN,zh_TW,pt_BR,ar,hi,in,tr,ru,pl"
        # Remove duplicates
  LOCALES=$(echo "${LOCALES}" | tr ',' '\n' | awk '!seen[$0]++' | tr '\n' ',' | sed 's/,$//')
fi

# CPU platforms
SUPPORTED_ABIS=$(get_prop "ro.product.cpu.abilist" "${PROP_FILE}")
# Map ABIs to Platforms field
PLATFORMS="${SUPPORTED_ABIS//;/,}"

# Screen metrics
read -r SCREEN_WIDTH SCREEN_HEIGHT SCREEN_DENSITY <<< "$(extract_screen_metrics "$(cat "${TEMP_DIR}/dumpsys_display.txt")")"
SCREEN_LAYOUT=$(calc_screen_layout "${SCREEN_WIDTH}" "${SCREEN_HEIGHT}" "${SCREEN_DENSITY}")

# GL info
read -r GL_VERSION GL_EXTENSIONS <<< "$(extract_gl_info "$(cat "${TEMP_DIR}/dumpsys_surface.txt")")"

# Features
DUMP_PKG=$(cat "${TEMP_DIR}/dumpsys_pkg.txt")
FEATURES=$(extract_features "${DUMP_PKG}")

# Shared Libraries
SHARED_LIBS=$(extract_shared_libraries "${DUMP_PKG}")

# Vending (Google Play Store) version
VENDING_OUTPUT=$(adb_shell "dumpsys package com.android.vending" 2>/dev/null || echo "")
VENDING_VERSION=$(extract_version_code "${VENDING_OUTPUT}")
VENDING_VERSION_STRING=$(extract_version_name "${VENDING_OUTPUT}")

# GSF (Google Services Framework) version
GSF_OUTPUT=$(adb_shell "dumpsys package com.google.android.gsf" 2>/dev/null || echo "")
GSF_VERSION=$(extract_version_code "${GSF_OUTPUT}")

# Radio / baseband version
RADIO=$(extract_radio "${PROP_FILE}")

# Timezone
TIMEZONE=$(get_prop "persist.sys.timezone" "${PROP_FILE}")
if [[ -z "${TIMEZONE}" ]]; then
  TIMEZONE="UTC-10"    # default fallback
fi

# UserReadableName
if [[ -z "${READABLE_NAME}" ]]; then
  echo -n "Enter device name (e.g. 'Galaxy S25 Ultra'): "
  read -r READABLE_NAME
fi
if [[ -z "${READABLE_NAME}" ]]; then
  READABLE_NAME="${BUILD_MODEL:-Unknown Device}"
fi

# --- Generate output file ----------------------------------------------------
TIMESTAMP=$(date +%Y%m%d)
MODEL_SLUG=$(printf '%s' "${BUILD_MODEL}" | tr -c '[:alnum:]. _-' '_' | tr ' ' '_' | head -c 30)
OUTPUT_FILE="${PROFILES_DIR}/${TIMESTAMP}_${MODEL_SLUG}.properties"

mkdir -p "${PROFILES_DIR}"

cat > "${OUTPUT_FILE}" <<PROPEOF
#
# SPDX-FileCopyrightText: 2020 AuroraOSS
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Generated by gather-deviceproperties.sh on $(date -u '+%Y-%m-%d %H:%M UTC')
# Device: ${READABLE_NAME}
#

UserReadableName=${READABLE_NAME}
Build.BOOTLOADER=${BUILD_BOOTLOADER}
Build.BRAND=${BUILD_BRAND}
Build.DEVICE=${BUILD_DEVICE}
Build.FINGERPRINT=${BUILD_FINGERPRINT}
Build.HARDWARE=${BUILD_HARDWARE}
Build.ID=${BUILD_ID}
Build.MANUFACTURER=${BUILD_MANUFACTURER}
Build.MODEL=${BUILD_MODEL}
Build.PRODUCT=${BUILD_PRODUCT}
Build.RADIO=${RADIO}
Build.VERSION.RELEASE=${BUILD_VERSION_RELEASE}
Build.VERSION.SDK_INT=${BUILD_VERSION_SDK}
CellOperator=${CELL_OPERATOR}
Client=android-google
Features=${FEATURES}
GL.Extensions=${GL_EXTENSIONS}
GL.Version=${GL_VERSION}
GSF.version=${GSF_VERSION}
HasFiveWayNavigation=false
HasHardKeyboard=false
Keyboard=1
Locales=${LOCALES}
Navigation=1
Platforms=${PLATFORMS}
Roaming=mobile-notroaming
Screen.Density=${SCREEN_DENSITY}
Screen.Height=${SCREEN_HEIGHT}
Screen.Width=${SCREEN_WIDTH}
ScreenLayout=${SCREEN_LAYOUT}
SharedLibraries=${SHARED_LIBS}
SimOperator=${SIM_OPERATOR}
TimeZone=${TIMEZONE}
TouchScreen=3
Vending.version=${VENDING_VERSION}
Vending.versionString=${VENDING_VERSION_STRING}
PROPEOF

info "Profile written to: ${OUTPUT_FILE}"
info "Device: ${READABLE_NAME} (${BUILD_MODEL})"
info "Android ${BUILD_VERSION_RELEASE} (SDK ${BUILD_VERSION_SDK})"
info "Platform: ${PLATFORMS}"
info "Screen: ${SCREEN_WIDTH}x${SCREEN_HEIGHT} @ ${SCREEN_DENSITY}dpi"
info "Play Store version: ${VENDING_VERSION_STRING} (${VENDING_VERSION})"
info "GSF version: ${GSF_VERSION}"
