#!/bin/bash
# Unified keyboard backlight control — single-zone RGB
# Combines named color presets + raw hex/decimal input
# Usage: ./kbd.sh <brightness> [color]
#        ./kbd.sh list
#        ./kbd.sh zones

set -euo pipefail

ZONE="rgb:kbd_backlight"
SYSFS_PATH="/sys/class/leds/$ZONE"

# --- Named Color Presets ---
declare -A COLORS=(
    [white]="255 255 255" [red]="255 0 0" [orange]="255 136 0" [gold]="255 215 0"
    [yellow]="255 255 0" [lime]="0 255 0" [green]="0 200 0" [teal]="0 128 128"
    [cyan]="0 255 255" [blue]="0 0 255" [navy]="0 0 128" [indigo]="75 0 130"
    [violet]="238 130 238" [purple]="136 0 255" [magenta]="255 0 255" [pink]="255 20 147"
    [coral]="255 127 80" [salmon]="250 128 114" [turquoise]="64 224 208" [olive]="128 128 0"
    [maroon]="128 0 0" [chocolate]="210 105 30" [gray]="128 128 128" [silver]="192 192 192"
    [off]="0 0 0"
)

usage() {
    cat <<EOF
Usage: $0 <brightness> [color]
       $0 list
       $0 zones

  brightness   0-255
  color        Named color, RRGGBB hex, RGB shorthand hex, or R,G,B decimal
               If omitted, defaults to white

Commands:
  list         Print all named colors with hex values
  zones        List available sysfs LED zones

Examples:
  $0 255 red          Full red (named)
  $0 128 ff8000       Orange at half brightness (hex)
  $0 255 f00          Full red (shorthand hex)
  $0 100 0,255,0      Dim green (decimal)
  $0 0                Turn off
EOF
    exit 0
}

list_colors() {
    echo "Available named colors:"
    local name
    while IFS= read -r name; do
        local rgb
        read -ra rgb <<< "${COLORS[$name]}"
        printf "  %-12s  #%02x%02x%02x\n" "$name" "${rgb[0]}" "${rgb[1]}" "${rgb[2]}"
    done < <(printf '%s\n' "${!COLORS[@]}" | sort)
}

list_zones() {
    if [[ -d "$SYSFS_PATH" ]]; then
        local max_bri
        max_bri=$(cat "$SYSFS_PATH/max_brightness" 2>/dev/null || echo "?")
        echo "  $ZONE (max_brightness=$max_bri)"
    else
        echo "  $ZONE — NOT AVAILABLE"
    fi
}

# --- Parse commands ---
case "${1:-}" in
    -h|--help|help) usage ;;
    list|--list)    list_colors; exit 0 ;;
    zones|-l)       list_zones; exit 0 ;;
esac

# Require at least brightness
if [[ $# -lt 1 ]]; then
    echo "Error: brightness argument is required." >&2
    usage
fi

# --- Root check & re-exec ---
if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

BRIGHTNESS="$1"
shift

# Validate brightness
if ! [[ "$BRIGHTNESS" =~ ^[0-9]+$ ]] || (( BRIGHTNESS > 255 )); then
    echo "Error: brightness must be 0-255, got '$BRIGHTNESS'" >&2
    exit 1
fi

# --- Parse color ---
R=0; G=0; B=0

if [[ $# -eq 0 ]]; then
    # No color given → default to white
    COLOR_LABEL="white"
    R=255; G=255; B=255
else
    SPEC="$1"

    if [[ -n "${COLORS[$SPEC]:-}" ]]; then
        # Named color
        read -ra rgb_parts <<< "${COLORS[$SPEC]}"
        R="${rgb_parts[0]}"
        G="${rgb_parts[1]}"
        B="${rgb_parts[2]}"
        COLOR_LABEL="$SPEC"
        if [[ "$SPEC" == "off" ]]; then
            BRIGHTNESS=0
        fi
    elif [[ "$SPEC" =~ ^[0-9a-fA-F]{6}$ ]]; then
        # RRGGBB hex
        R=$((16#${SPEC:0:2}))
        G=$((16#${SPEC:2:2}))
        B=$((16#${SPEC:4:2}))
        COLOR_LABEL="#${SPEC}"
    elif [[ "$SPEC" =~ ^[0-9a-fA-F]{3}$ ]]; then
        # RGB shorthand hex (e.g. f00 → ff0000)
        R=$((16#${SPEC:0:1}${SPEC:0:1}))
        G=$((16#${SPEC:1:1}${SPEC:1:1}))
        B=$((16#${SPEC:2:1}${SPEC:2:1}))
        COLOR_LABEL="#${SPEC:0:1}${SPEC:0:1}${SPEC:1:1}${SPEC:1:1}${SPEC:2:1}${SPEC:2:1}"
    elif [[ "$SPEC" =~ ^[0-9]+,[0-9]+,[0-9]+$ ]]; then
        # Decimal R,G,B
        IFS=',' read -r R G B <<< "$SPEC"
        COLOR_LABEL="rgb($R,$G,$B)"
    else
        echo "Error: invalid color '$SPEC'. Use named color, RRGGBB, RGB, or R,G,B." >&2
        exit 1
    fi
fi

# Validate R, G, B are in range 0-255
for val in "$R" "$G" "$B"; do
    if ! [[ "$val" =~ ^[0-9]+$ ]] || (( val > 255 )); then
        echo "Error: color values must be 0-255, got '$val'" >&2
        exit 1
    fi
done

# --- Write to sysfs ---
if [[ ! -d "$SYSFS_PATH" ]]; then
    echo "Error: $SYSFS_PATH not found. Is tuxedo_keyboard loaded?" >&2
    echo "Try: sudo modprobe tuxedo_keyboard force_backlight_type=6" >&2
    exit 1
fi

echo "$R $G $B" > "$SYSFS_PATH/multi_intensity"
echo "$BRIGHTNESS" > "$SYSFS_PATH/brightness"

if (( BRIGHTNESS > 0 )); then
    printf "Keyboard → %s at brightness %d\n" "${COLOR_LABEL:-rgb($R,$G,$B)}" "$BRIGHTNESS"
else
    echo "Keyboard lights off"
fi
