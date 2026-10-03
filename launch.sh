#!/bin/sh
# BaseOS updater for NextUI on Anbernic RG XX (h700).
#
# BaseOS updates itself from a .bosupd file at the root of the frontend card:
# it applies the update at the next boot and removes the file afterwards. This
# works out which file this model needs, downloads it from the BaseOS releases,
# checks it, and reboots.

PAK_DIR="$(dirname "$0")"
cd "$PAK_DIR" || exit 1

SD_ROOT="${SDCARD_PATH:-/mnt/SDCARD}"
LOG="${LOGS_PATH:-$SD_ROOT}/BaseOS Updater.txt"
API="https://api.github.com/repos/pvaibhav/BaseOS/releases/latest"
MANUAL_HELP="Download your model's .bosupd from github.com/pvaibhav/BaseOS, copy it to the root of your SD card and restart."
TMP=/tmp/baseos_updater
PRESENTER="$PAK_DIR/bin/minui-presenter"

mkdir -p "$TMP"
: > "$LOG"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

show() {
    "$PRESENTER" --message "$1" --timeout 0 --confirm-show --confirm-text "OK" > /dev/null 2>&1
}

# Exit 0 on A, anything else (B, timeout) means no.
ask() {
    "$PRESENTER" --message "$1" --timeout 0 --confirm-show --confirm-text "$2" \
        --cancel-show --cancel-text "CANCEL" > /dev/null 2>&1
}

# Shown until killed.
busy_start() {
    "$PRESENTER" --message "$1" --timeout -1 > /dev/null 2>&1 &
    BUSY_PID=$!
}

busy_stop() {
    [ -n "$BUSY_PID" ] && kill "$BUSY_PID" 2> /dev/null && wait "$BUSY_PID" 2> /dev/null
    BUSY_PID=""
}

bail() {
    busy_stop
    log "stopped: $1"
    show "$1"
    rm -rf "$TMP"
    exit 1
}

baseos_field() {
    sed -n "s/^$1=//p" /etc/baseos-release 2> /dev/null | tr -d '"'
}

# 1.2.3 -> 1002003, for a plain numeric comparison. Prints nothing if the
# version is not three numbers, and every caller treats that as "no opinion".
version_num() {
    case "$1" in
        '' | *[!0-9.]*) return 1 ;;
    esac
    printf '%s' "$1" | awk -F. '{printf "%d%03d%03d", $1, $2, $3}'
}

# One line per release asset: name, size, url. The API's JSON lists each
# asset's name, then its size, then its download URL.
list_assets() {
    awk -F'"' '
        $2 == "name" { name = $4 }
        $2 == "size" { size = $3; gsub(/[^0-9]/, "", size) }
        $2 == "browser_download_url" { print name, size, $4 }
    ' "$TMP/release.json"
}

battery_ok() {
    for _b in /sys/class/power_supply/*; do
        [ "$(cat "$_b/type" 2> /dev/null)" = "Battery" ] || continue
        _cap="$(cat "$_b/capacity" 2> /dev/null)"
        _status="$(cat "$_b/status" 2> /dev/null)"
        [ "$_status" = "Discharging" ] && [ "${_cap:-100}" -lt 15 ] 2> /dev/null && return 1
        return 0
    done
    return 0
}

INSTALLED="$(baseos_field BASEOS_VERSION)"
TARGET="$(baseos_field BASEOS_TARGET)"
log "installed ${INSTALLED:-unknown}, target ${TARGET:-unknown}"
[ -n "$TARGET" ] || bail "Could not tell which BaseOS build this device runs, so there is nothing safe to download.\n\n$MANUAL_HELP"

ask "BaseOS ${INSTALLED:-(unknown version)} is installed.\n\nCheck for a newer one?" "CHECK" || exit 0

busy_start "Checking for a BaseOS update..."
if ! curl -sf -m 20 -o "$TMP/release.json" "$API"; then
    bail "Could not reach GitHub to look for a BaseOS update.\n\nMake sure WiFi is on and connected in Settings, then try again."
fi
busy_stop

LATEST="$(sed -n 's/^ *"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' "$TMP/release.json" | head -n 1)"
ASSET_LINE="$(list_assets | awk -v t="baseos-${TARGET}-" 'index($1, t) == 1 && $1 ~ /\.bosupd$/' | head -n 1)"
ASSET_NAME="$(echo "$ASSET_LINE" | cut -d' ' -f1)"
ASSET_SIZE="$(echo "$ASSET_LINE" | cut -d' ' -f2)"
ASSET_URL="$(echo "$ASSET_LINE" | cut -d' ' -f3)"
SUMS_URL="$(list_assets | awk '$1 == "SHA256SUMS" {print $3}' | head -n 1)"
log "latest ${LATEST:-unknown}, asset ${ASSET_NAME:-none} (${ASSET_SIZE:-?} bytes)"

if [ -z "$ASSET_NAME" ] || [ -z "$ASSET_URL" ]; then
    bail "BaseOS ${LATEST:-latest} has no update file for this model ($TARGET), so it has to be installed by hand.\n\n$MANUAL_HELP"
fi

if [ -n "$INSTALLED" ]; then
    _have="$(version_num "$INSTALLED")"
    _latest="$(version_num "$LATEST")"
    if [ -n "$_have" ] && [ -n "$_latest" ] && [ "$_have" -ge "$_latest" ] 2> /dev/null; then
        log "already up to date"
        show "BaseOS $INSTALLED is already the latest version."
        rm -rf "$TMP"
        exit 0
    fi
fi

FREE_MB="$(df -m "$SD_ROOT" | awk 'END {print $4}')"
NEED_MB=$(( (${ASSET_SIZE:-0} / 1048576) + 50 ))
if [ "${FREE_MB:-0}" -lt "$NEED_MB" ] 2> /dev/null; then
    bail "Not enough free space for the BaseOS update: ${NEED_MB} MiB needed, ${FREE_MB} MiB free."
fi

battery_ok || bail "Please charge your device to at least 15%, or plug it in, then try again."

ask "BaseOS $LATEST is available (you have ${INSTALLED:-an unknown version}).\n\nDownload and install it now?" "INSTALL" || {
    log "cancelled"
    rm -rf "$TMP"
    exit 0
}

busy_start "Downloading BaseOS $LATEST ($(( ${ASSET_SIZE:-0} / 1048576 )) MiB)...\n\nPlease wait."
if ! curl -sfL -m 1800 -o "$SD_ROOT/$ASSET_NAME" "$ASSET_URL"; then
    rm -f "$SD_ROOT/$ASSET_NAME"
    bail "The BaseOS update could not be downloaded. Please try again later."
fi

# A truncated or corrupt update file is worse than none: BaseOS would try to
# apply it at boot. Check it against the release's own SHA256SUMS, and only
# skip the check if that file could not be fetched.
if [ -n "$SUMS_URL" ] && command -v sha256sum > /dev/null 2>&1 && curl -sfL -m 20 -o "$TMP/sums" "$SUMS_URL"; then
    WANT="$(awk -v n="$ASSET_NAME" '$2 == n || $2 == "*"n {print $1}' "$TMP/sums" | head -n 1)"
    GOT="$(sha256sum "$SD_ROOT/$ASSET_NAME" | cut -d' ' -f1)"
    if [ -n "$WANT" ] && [ "$WANT" != "$GOT" ]; then
        rm -f "$SD_ROOT/$ASSET_NAME"
        bail "The downloaded BaseOS update was damaged in transit and has been deleted. Please try again."
    fi
    log "checksum ok"
else
    log "WARNING: could not check the download (no SHA256SUMS or sha256sum)"
fi
sync
busy_stop
rm -rf "$TMP"

log "ready, rebooting"
show "BaseOS $LATEST is ready to install.\n\nYour device will now restart and apply the update. Keep it plugged in or charged, and let it finish without switching it off."
touch /tmp/reboot
