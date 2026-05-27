#!/bin/bash
# Keyboard breathing effect — smooth brightness fade, rainbow, preset, or color cycling
# Usage: ./kbd-breathing.sh [options]

set -euo pipefail

ZONE="rgb:kbd_backlight"
SYSFS_PATH="/sys/class/leds/$ZONE"
STEPS=60

# Defaults
COLOR_HEX="ffffff"
CYCLE_SEC=3
MIN_BRI=8
MAX_BRI=255
MODE="static"  # static | rainbow | presetcycle | colorcycle
COLORCYCLE_LIST=()

# Curated preset colors for -p mode
PRESET_COLORS=(
    ff0000  # red
    ff8800  # orange
    ffff00  # yellow
    00ff00  # lime
    00ccff  # cyan
    0066ff  # blue
    8800ff  # purple
    ff00ff  # magenta
)

usage() {
    cat <<EOF
Usage: $0 [options]

Smoothly fades the keyboard backlight brightness up and down.

Options:
  -c <RRGGBB>   Static color in hex (default: ffffff)
  -r            Rainbow — hues cycle continuously while breathing
  -p            Preset cycle — one curated color per breath (auto-advance)
  -C <list>     Custom color cycle — comma-separated RRGGBB, one per breath
  -s <seconds>  Breathing cycle duration (default: 3)
  -m <min>      Minimum brightness 0-255 (default: 8)
  -M <max>      Maximum brightness 0-255 (default: 255)
  -h            Show this help

Modes (mutually exclusive, last wins):
  -c <color>    Static single color with breathing (default)
  -r            Rainbow: hue sweeps every step while breathing
  -p            Preset cycle: one color per full breath, auto-advance
  -C <list>     Custom cycle: your own colors, one per breath

Press Ctrl+C to stop.
EOF
    exit 0
}

# --- Parse options ---
while getopts ":c:rps:C:m:M:h" opt; do
    case "$opt" in
        c) COLOR_HEX="$OPTARG"; MODE="static" ;;
        r) MODE="rainbow" ;;
        p) MODE="presetcycle" ;;
        C) MODE="colorcycle"; IFS=',' read -ra COLORCYCLE_LIST <<< "$OPTARG" ;;
        s) CYCLE_SEC="$OPTARG" ;;
        m) MIN_BRI="$OPTARG" ;;
        M) MAX_BRI="$OPTARG" ;;
        h) usage ;;
        :) echo "Error: -$OPTARG requires an argument" >&2; exit 1 ;;
        *) echo "Error: unknown option -$OPTARG" >&2; exit 1 ;;
    esac
done

# --- Root check & re-exec ---
if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

# --- Sysfs check ---
if [[ ! -d "$SYSFS_PATH" ]]; then
    echo "Error: $SYSFS_PATH not found. Is tuxedo_keyboard loaded?" >&2
    exit 1
fi

# --- Save original state for restore on exit ---
ORIG_RGB=$(cat "$SYSFS_PATH/multi_intensity" 2>/dev/null || echo "255 255 255")
ORIG_BRI=$(cat "$SYSFS_PATH/brightness" 2>/dev/null || echo 0)

# --- Validation ---
for var in "$CYCLE_SEC" "$MIN_BRI" "$MAX_BRI"; do
    if ! [[ "$var" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "Error: expected a number, got '$var'" >&2
        exit 1
    fi
done

# Range check brightness values
if (( MIN_BRI < 0 || MIN_BRI > 255 || MAX_BRI < 0 || MAX_BRI > 255 )); then
    echo "Error: MIN_BRI and MAX_BRI must be 0-255" >&2
    exit 1
fi

# --- Precompute animation table ---
BRI_TABLE=()
RGB_TABLE=()

gen_sine_table() {
    awk -v n="$STEPS" -v min="$MIN_BRI" -v max="$MAX_BRI" -v pi="3.14159265" '
    BEGIN {
        range = max - min
        for (i = 0; i < n; i++) {
            angle = -pi/2 + (i / n) * 2 * pi
            s = (sin(angle) + 1) / 2
            printf "%d\n", int(min + s * range + 0.5)
        }
    }'
}

mapfile -t BRI_TABLE < <(gen_sine_table)

case "$MODE" in
    static)
        if ! [[ "$COLOR_HEX" =~ ^[0-9a-fA-F]{6}$ ]]; then
            echo "Error: invalid hex color '$COLOR_HEX'" >&2; exit 1
        fi
        R=$((16#${COLOR_HEX:0:2}))
        G=$((16#${COLOR_HEX:2:2}))
        B=$((16#${COLOR_HEX:4:2}))
        for ((i=0; i<STEPS; i++)); do RGB_TABLE+=("$R $G $B"); done
        ;;
    rainbow)
        mapfile -t RGB_TABLE < <(awk -v n="$STEPS" '
        function hsv_to_rgb(h, s, v,  i, f, p, q, t) {
            h %= 360; s /= 100; v /= 100
            i = int(h / 60); f = (h / 60) - i
            p = v * (1 - s); q = v * (1 - s * f); t = v * (1 - s * (1 - f))
            if (i == 0) return sprintf("%d %d %d", v*255, t*255, p*255)
            if (i == 1) return sprintf("%d %d %d", q*255, v*255, p*255)
            if (i == 2) return sprintf("%d %d %d", p*255, v*255, t*255)
            if (i == 3) return sprintf("%d %d %d", p*255, q*255, v*255)
            if (i == 4) return sprintf("%d %d %d", t*255, p*255, v*255)
            return sprintf("%d %d %d", v*255, p*255, q*255)
        }
        BEGIN { for (i = 0; i < n; i++) print hsv_to_rgb((i/n)*360, 100, 100) }')
        ;;
    presetcycle)
        for c in "${PRESET_COLORS[@]}"; do
            R=$((16#${c:0:2})); G=$((16#${c:2:2})); B=$((16#${c:4:2}))
            for ((i=0; i<STEPS; i++)); do RGB_TABLE+=("$R $G $B"); done
        done
        ;;
    colorcycle)
        for c in "${COLORCYCLE_LIST[@]}"; do
            if ! [[ "$c" =~ ^[0-9a-fA-F]{6}$ ]]; then
                echo "Error: invalid color '$c'" >&2; exit 1
            fi
            R=$((16#${c:0:2})); G=$((16#${c:2:2})); B=$((16#${c:4:2}))
            for ((i=0; i<STEPS; i++)); do RGB_TABLE+=("$R $G $B"); done
        done
        ;;
esac

# --- Breathing loop ---
SLEEP_PER_STEP=$(awk -v s="$CYCLE_SEC" -v n="$STEPS" 'BEGIN { printf "%.4f", s / n }')

# Restore original keyboard state on exit (any signal or normal exit)
trap 'echo ""; echo "Restoring original state..."
      echo "$ORIG_RGB" > "$SYSFS_PATH/multi_intensity" 2>/dev/null || true
      echo "$ORIG_BRI" > "$SYSFS_PATH/brightness" 2>/dev/null || true' EXIT

printf "Breathing mode: %s (%d\u2194%d) \u2014 Ctrl+C to stop\n" "$MODE" "$MIN_BRI" "$MAX_BRI"

IDX=0
TOTAL_RGB=${#RGB_TABLE[@]}
LAST_RGB=""
LAST_BRI=""

while true; do
    rgb="${RGB_TABLE[$IDX]}"
    # brightness index wraps at STEPS so each color gets a full breath
    bri="${BRI_TABLE[$((IDX % STEPS))]}"

    # Only write if value changed
    if [[ "$rgb" != "$LAST_RGB" ]]; then
        echo "$rgb" > "$SYSFS_PATH/multi_intensity"
        LAST_RGB="$rgb"
    fi
    if [[ "$bri" != "$LAST_BRI" ]]; then
        echo "$bri" > "$SYSFS_PATH/brightness"
        LAST_BRI="$bri"
    fi

    IDX=$(( (IDX + 1) % TOTAL_RGB ))
    sleep "$SLEEP_PER_STEP"
done
