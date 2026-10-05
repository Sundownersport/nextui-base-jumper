#!/bin/sh

PAK_DIR="$(dirname "$0")"
cd "$PAK_DIR" || exit 1

SD_ROOT="${SDCARD_PATH:-/mnt/SDCARD}"
LOG="${LOGS_PATH:-$SD_ROOT}/Base Jumper.txt"
API="https://api.github.com/repos/pvaibhav/BaseOS/releases/latest"
MANUAL_HELP="Download your model's .bosupd from github.com/pvaibhav/BaseOS, copy it to the root of your SD card and restart."
NO_WIFI="WiFi is off or not connected.\n\nTurn it on in Settings, then try again."
TMP=/tmp/baseos_updater
PRESENTER="$PAK_DIR/bin/minui-presenter"

mkdir -p "$TMP"
rm -f "$SD_ROOT"/baseos-*.bosupd.part
: > "$LOG"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

show() {
    "$PRESENTER" --message "$1" --timeout 0 --confirm-show --confirm-text "OK" > /dev/null 2>&1
}

ask() {
    "$PRESENTER" --message "$1" --timeout 0 --confirm-show --confirm-text "$2" \
        --cancel-show --cancel-text "CANCEL" > /dev/null 2>&1
}

busy_start() {
    "$PRESENTER" --message "$1" --timeout -1 > /dev/null 2>&1 &
    BUSY_PID=$!
}

busy_stop() {
    [ -n "$BUSY_PID" ] || return 0
    kill "$BUSY_PID" 2> /dev/null
    for _i in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$BUSY_PID" 2> /dev/null || break
        sleep 0.2
    done
    kill -9 "$BUSY_PID" 2> /dev/null
    wait "$BUSY_PID" 2> /dev/null
    BUSY_PID=""
}

cleanup() {
    busy_stop
    [ -n "$PART" ] && rm -f "$PART"
    rm -rf "$TMP"
}
trap cleanup EXIT

bail() {
    busy_stop
    log "stopped: $1"
    show "$1"
    exit 1
}

baseos_field() {
    sed -n "s/^$1=//p" /etc/baseos-release 2> /dev/null | tr -d '"'
}

version_num() {
    case "$1" in
        '' | *[!0-9.]*) return 1 ;;
    esac
    printf '%s' "$1" | awk -F. '{printf "%d%03d%03d", $1, $2, $3}'
}

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

awk '$2 == "00000000" { found = 1 } END { exit !found }' /proc/net/route 2> /dev/null || bail "$NO_WIFI"

busy_start "Checking for a BaseOS update..."
timeout 30 curl -sf --connect-timeout 10 -m 20 -o "$TMP/release.json" "$API"
RC=$?
log "release check: curl exit $RC"
case $RC in
    0) ;;
    6 | 7) bail "$NO_WIFI" ;;
    35 | 60) bail "Could not make a secure connection to GitHub. This usually means the date and time are wrong.\n\nSet them with the Clock tool, then try again." ;;
    28 | 124 | 143) bail "GitHub took too long to answer. Check your WiFi signal and try again." ;;
    *) bail "Could not reach GitHub to look for a BaseOS update.\n\nMake sure WiFi is on and connected in Settings, then try again." ;;
esac
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
        exit 0
    fi
fi

FREE_MB="$(df -m "$SD_ROOT" | awk 'END {print $4}')"
NEED_MB=$(( (${ASSET_SIZE:-0} / 1048576) + 50 ))
if [ "${FREE_MB:-0}" -lt "$NEED_MB" ] 2> /dev/null; then
    bail "Not enough free space for the BaseOS update: ${NEED_MB} MiB needed, ${FREE_MB} MiB free."
fi

battery_ok || bail "Please charge your device to at least 15%, or plug it in, then try again."

ask "BaseOS $LATEST is available\n(you have ${INSTALLED:-an unknown version}).\n\nDownload and install it now?" "INSTALL" || {
    log "cancelled"
    exit 0
}

PART="$SD_ROOT/$ASSET_NAME.part"
busy_start "Downloading BaseOS $LATEST\n($(( ${ASSET_SIZE:-0} / 1048576 )) MiB)...\n\nPlease wait."
curl -sfL --connect-timeout 10 -m 1800 -o "$PART" "$ASSET_URL"
RC=$?
log "download: curl exit $RC"
[ "$RC" -eq 0 ] || bail "The BaseOS update could not be downloaded. Please try again later."

GOT_SIZE="$(wc -c < "$PART" | tr -d ' ')"
if [ -n "$ASSET_SIZE" ] && [ "$GOT_SIZE" != "$ASSET_SIZE" ]; then
    log "size mismatch: got $GOT_SIZE, want $ASSET_SIZE"
    bail "The BaseOS update did not download completely. Please try again."
fi

if [ -n "$SUMS_URL" ] && command -v sha256sum > /dev/null 2>&1 && curl -sfL --connect-timeout 10 -m 20 -o "$TMP/sums" "$SUMS_URL"; then
    WANT="$(awk -v n="$ASSET_NAME" '$2 == n || $2 == "*"n {print $1}' "$TMP/sums" | head -n 1)"
    GOT="$(sha256sum "$PART" | cut -d' ' -f1)"
    if [ -z "$WANT" ]; then
        log "WARNING: $ASSET_NAME is not listed in SHA256SUMS"
    elif [ "$WANT" != "$GOT" ]; then
        bail "The downloaded BaseOS update was damaged in transit and has been deleted. Please try again."
    else
        log "checksum ok"
    fi
else
    log "WARNING: could not check the download (no SHA256SUMS or sha256sum)"
fi

mv "$PART" "$SD_ROOT/$ASSET_NAME" || bail "Could not save the BaseOS update to the SD card. Please try again."
PART=""
sync
busy_stop

log "ready, rebooting"
show "BaseOS $LATEST is ready to install.\n\nYour device will now restart and apply the update. Keep it plugged in or charged, and let it finish without switching it off."
touch /tmp/reboot
