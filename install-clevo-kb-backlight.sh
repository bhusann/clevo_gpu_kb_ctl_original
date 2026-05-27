#!/bin/bash
#
# Clevo Keyboard Backlight Fix — Colorful P15 23 / generic Clevo
# ==============================================================
#
# This script:
#   1. Clones the NovaCustom clevo-keyboard driver (tuxedo_keyboard fork)
#   2. Patches DMI vendor strings to match your laptop
#   3. Applies force_backlight_type patch for laptops where KBTP=0
#   4. Builds and installs via DKMS
#   5. Configures auto-load with force_backlight_type=6 (1-zone RGB)
#
# After reboot, control via:
#   /sys/class/leds/rgb:kbd_backlight/multi_intensity
#
# Usage: sudo bash install-clevo-kb-backlight.sh
#

set -euo pipefail

echo "=== Clevo Keyboard Backlight Fix ==="
echo ""

# --- Prerequisites ---
echo ">>> Installing build dependencies..."
if command -v pacman &>/dev/null; then
    pacman -Sy --noconfirm git dkms base-devel linux-headers 2>/dev/null || \
    pacman -Sy --noconfirm git dkms base-devel  # fallback
elif command -v apt &>/dev/null; then
    apt update && apt install -y git dkms build-essential linux-headers-$(uname -r)
elif command -v dnf &>/dev/null; then
    dnf -y group install "Development Tools" && dnf -y install git dkms kernel-devel
else
    echo "WARNING: unknown distro — ensure git, dkms, and kernel headers are installed"
fi

# --- Clean old builds ---
echo ">>> Cleaning previous installations..."
rmmod clevo_acpi clevo_wmi tuxedo_keyboard 2>/dev/null || true
dkms remove -m tuxedo-keyboard -v 3.2.10 --all 2>/dev/null || true
rm -rf /usr/src/tuxedo-keyboard-3.2.10
rm -f /etc/modprobe.d/tuxedo_keyboard.conf

# --- Clone repo ---
BUILD_DIR=$(mktemp -d)
echo ">>> Cloning NovaCustom clevo-keyboard into $BUILD_DIR ..."
git clone https://github.com/wessel-novacustom/clevo-keyboard "$BUILD_DIR" 2>/dev/null

# --- Patch DMI vendor strings ---
echo ">>> Patching DMI vendor strings..."
SYSVEN=$(cat /sys/class/dmi/id/sys_vendor)
BDVEN=$(cat /sys/class/dmi/id/board_vendor)
CHVEN=$(cat /sys/class/dmi/id/chassis_vendor)

sed -i "s/DMI_MATCH(DMI_SYS_VENDOR, \".*\")/DMI_MATCH(DMI_SYS_VENDOR, \"$SYSVEN\")/g" \
    "$BUILD_DIR/src/tuxedo_keyboard.c"
sed -i "s/DMI_MATCH(DMI_BOARD_VENDOR, \".*\")/DMI_MATCH(DMI_BOARD_VENDOR, \"$BDVEN\")/g" \
    "$BUILD_DIR/src/tuxedo_keyboard.c"
sed -i "s/DMI_MATCH(DMI_CHASSIS_VENDOR, \".*\")/DMI_MATCH(DMI_CHASSIS_VENDOR, \"$CHVEN\")/g" \
    "$BUILD_DIR/src/tuxedo_keyboard.c"

echo "   DMI_SYS_VENDOR    = $SYSVEN"
echo "   DMI_BOARD_VENDOR  = $BDVEN"
echo "   DMI_CHASSIS_VENDOR = $CHVEN"

# --- Apply force_backlight_type patch ---
echo ">>> Applying force_backlight_type patch..."
patch -d "$BUILD_DIR" -p1 <<'PATCH_EOF'
--- a/src/clevo_leds.h
+++ b/src/clevo_leds.h
@@ -66,6 +66,11 @@
 static enum clevo_kb_backlight_types clevo_kb_backlight_type = CLEVO_KB_BACKLIGHT_TYPE_NONE;
 static bool leds_initialized = false;

+static int param_force_backlight_type = 0;
+module_param_named(force_backlight_type, param_force_backlight_type, int, 0444);
+MODULE_PARM_DESC(force_backlight_type, "Force keyboard backlight type: "
+	"0=auto/detect, 1=fixed-white, 2=3-zone-RGB, 6=1-zone-RGB");
+
 /**
  * Color scaling quirk list
  */
@@ -358,6 +363,13 @@
 	}
 	pr_debug("Keyboard backlight type: 0x%02x\n", clevo_kb_backlight_type);

+	// Override with module parameter if set
+	if (param_force_backlight_type > 0) {
+		clevo_kb_backlight_type = param_force_backlight_type;
+		TUXEDO_INFO("Keyboard backlight type overridden by module param: "
+			"0x%02x\n", clevo_kb_backlight_type);
+	}
+
 	if (clevo_kb_backlight_type == CLEVO_KB_BACKLIGHT_TYPE_FIXED_COLOR)
 		clevo_leds_set_brightness_extern(clevo_led_cdev.brightness);
 	else
PATCH_EOF

# --- DKMS install ---
echo ">>> Building and installing via DKMS..."
cp -R "$BUILD_DIR" /usr/src/tuxedo-keyboard-3.2.10
dkms install -m tuxedo-keyboard -v 3.2.10

# --- Configure auto-load ---
echo ">>> Configuring auto-load..."
cat > /etc/modprobe.d/tuxedo_keyboard.conf <<'CONF_EOF'
# Auto-load tuxedo_keyboard with forced backlight type
# 6 = 1-zone RGB (Colorful P15 23 and similar single-zone Clevo)
options tuxedo-keyboard force_backlight_type=6
CONF_EOF

# --- Load now ---
echo ">>> Loading modules..."
modprobe tuxedo_keyboard
modprobe clevo_acpi 2>/dev/null || true
modprobe clevo_wmi 2>/dev/null || true

# --- Verify ---
echo ""
echo "=== Verification ==="
echo ""
echo "Loaded modules:"
lsmod | grep -E 'tuxedo|clevo' || echo "(none)"
echo ""
echo "Keyboard LED interfaces:"
ls /sys/class/leds/ | grep kbd_backlight || echo "(none found)"
echo ""
echo "Light test — setting to red for 3 seconds..."
if [ -d /sys/class/leds/rgb:kbd_backlight ]; then
    echo "255 0 0" > /sys/class/leds/rgb:kbd_backlight/multi_intensity
    echo 255 > /sys/class/leds/rgb:kbd_backlight/brightness
    sleep 3
    echo 0 > /sys/class/leds/rgb:kbd_backlight/brightness
    echo "Done."
else
    echo "RGB LED interface not found — try: modprobe tuxedo_keyboard force_backlight_type=6"
fi

echo ""
echo "=== SUCCESS ==="
echo ""
echo "Control keyboard backlight at:"
echo "  /sys/class/leds/rgb:kbd_backlight/multi_intensity"
echo ""
echo "Set to white:"
echo '  echo "255 255 255" | sudo tee /sys/class/leds/rgb:kbd_backlight/multi_intensity'
echo '  echo 255 | sudo tee /sys/class/leds/rgb:kbd_backlight/brightness'
echo ""
echo "Or use the helper scripts:"
echo "  ./kbd-backlight.sh 255 white"
echo "  ./kbd-rgb.sh 255 ff0000"

# Cleanup
rm -rf "$BUILD_DIR"
