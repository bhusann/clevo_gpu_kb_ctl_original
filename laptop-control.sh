#!/usr/bin/env bash
# Colorful P15 Control Center
# Unified TUI for laptop power/performance/keyboard control
# Requires: whiptail (preinstalled)
set -uo pipefail

# ============================================================
# CONFIGURATION & INITIALIZATION
# ============================================================
SCRIPTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
POLYBAR_DIR="$HOME/.config/polybar/scripts"

GPU_PERF="$SCRIPTS_DIR/dep-scripts/gpu-perf.sh"
KBD_BREATHING="$SCRIPTS_DIR/dep-scripts/kbd-breathing.sh"
PL_SCRIPT="$SCRIPTS_DIR/dep-scripts/pl.sh"

LED_PATH="/sys/class/leds/rgb:kbd_backlight"
CPU_BASE="/sys/devices/system/cpu"
TURBO_PATH="/sys/devices/system/cpu/intel_pstate/no_turbo"
RAPL_ZONE="/sys/class/powercap/intel-rapl:0"
BREATHE_PID_FILE="${XDG_RUNTIME_DIR:-/tmp}/laptop-control-breathe-$UID.pid"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/laptop-control-$UID.lock"

# Lazy-loaded vars
NVIDIA_ADDR=""
NVIDIA_POWER_CTRL=""
INTEL_POWER_CTRL="/sys/bus/pci/devices/0000:00:02.0/power/control"

# Concurrency Lock
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Error: Another instance of laptop-control.sh is already running." >&2
    exit 1
fi
# Clean up lock file on exit (fd 9 closes automatically, but remove the file)
trap 'rm -f "$LOCK_FILE"' EXIT
trap 'exit' INT TERM HUP

init_gpu_vars() {
    [ -n "$NVIDIA_ADDR" ] && return
    NVIDIA_ADDR=$(lspci | grep -i nvidia | awk '{print "0000:"$1}' | head -n 1)
    NVIDIA_ADDR="${NVIDIA_ADDR:-0000:01:00.0}"
    NVIDIA_POWER_CTRL="/sys/bus/pci/devices/$NVIDIA_ADDR/power/control"
}

# ============================================================
# UTILITY FUNCTIONS
# ============================================================

msg() {
    whiptail --title "$1" --msgbox "$2" 12 65 3>&1 1>&2 2>&3
}

confirm() {
    whiptail --title "$1" --yesno "$2" 10 65 3>&1 1>&2 2>&3
}

inputbox() {
    whiptail --title "$1" --inputbox "$2" 10 65 "$3" 3>&1 1>&2 2>&3
}

run_root() {
    local title="$1" cmd="$2"
    if sudo bash -c "$cmd"; then
        msg "Success" "$title completed."
        return 0
    else
        msg "Error" "$title failed or was cancelled."
        return 1
    fi
}

kbd_write() {
    local file="$1" val="$2"
    if [ ! -w "$file" ]; then
        printf '%s' "$val" | sudo tee "$file" > /dev/null 2>&1 || true
    else
        printf '%s' "$val" > "$file" 2>/dev/null || true
    fi
}

# ============================================================
# NVIDIA GPU POWER OFF / ON (Experimental PCI Control)
# ============================================================

nvidia_gpu_off() {
    init_gpu_vars
    local gpu_id="${NVIDIA_ADDR#0000:}"
    local audio_id="${gpu_id%.0}.1"
    
    if ! confirm "Experimental: GPU Power Off" "This will kill all processes using the NVIDIA GPU and remove it from the PCI bus to force D3cold (zero power).\n\nContinue?"; then
        return
    fi

    local output
    if ! output=$(sudo bash -c "
        SYS='/sys/bus/pci/devices'
        GPU='0000:$gpu_id'
        AUD='0000:$audio_id'

        if [ ! -e \"\$SYS/\$GPU\" ]; then
            echo 'GPU is already removed.'
            exit 0
        fi

        # Kill userspace holding the GPU open
        fuser -sk /dev/nvidia* 2>/dev/null || true
        sleep 0.5

        # Attempt removal
        echo 1 > \"\$SYS/\$GPU/remove\" 2>/dev/null || exit 1
        [ -e \"\$SYS/\$AUD\" ] && echo 1 > \"\$SYS/\$AUD/remove\" 2>/dev/null
        
        # Verify
        if [ ! -e \"\$SYS/\$GPU\" ]; then
            echo 'SUCCESS: NVIDIA GPU has been removed from the bus.'
        else
            echo 'FAILED: GPU is still visible in sysfs.'
            exit 1
        fi
    " 2>&1); then
        msg "Error" "Failed to power off GPU:\n${output}"
        return 1
    fi
    msg "GPU Power Off" "$output"
}

nvidia_gpu_on() {
    local output
    if ! output=$(sudo bash -c '
        # Rescan the entire PCI bus to find the missing GPU
        echo 1 > /sys/bus/pci/rescan
        
        # Give the kernel a moment to re-initialize
        sleep 1.5

        # Check if the device is back and driver is bound
        # Use escaped variables to ensure they are evaluated inside the inner bash
        GPU_ADDR=$(lspci | grep -i nvidia | awk "{print \"0000:\"\$1}" | head -n 1)
        if [ -n "$GPU_ADDR" ] && [ -L "/sys/bus/pci/devices/$GPU_ADDR/driver" ]; then
            echo "SUCCESS: NVIDIA GPU is back and driver is bound ($GPU_ADDR)."
            exit 0
        fi
        
        # Try manual bind if driver didn'\''t attach automatically
        if [ -n "$GPU_ADDR" ]; then
            echo "$GPU_ADDR" > /sys/bus/pci/drivers/nvidia/bind 2>/dev/null && echo "SUCCESS: GPU re-bound manually." && exit 0
        fi

        echo "FAILED: GPU did not reappear or driver failed to bind."
        exit 1
    ' 2>&1); then
        msg "Error" "Failed to re-enable GPU:\n${output}"
        return 1
    fi
    msg "GPU Power On" "$output"
}

gpu_experimental_menu() {
    while true; do
        local choice
        choice=$(whiptail --title "Experimental: GPU PCI Control" \
            --menu "Physically disconnect/reconnect GPU from PCI bus.\nUse this for maximum power savings in battery mode." 14 65 3 \
            "1" "Power OFF (Remove from PCI)" \
            "2" "Power ON  (PCI Rescan)" \
            "3" "Back to main" \
            3>&1 1>&2 2>&3) || break
        [ -z "$choice" ] || [ "$choice" = "3" ] && break
        case "$choice" in
            1) nvidia_gpu_off ;;
            2) nvidia_gpu_on ;;
        esac
    done
}

# ============================================================
# COMBINED PROFILES
# ============================================================

# Helper: build a batch script for all root-level profile commands
# (excluding gpu-perf.sh which handles its own sudo internally)
profile_batch() {
    cat <<'EOF'
fail=0;
mark_fail() { echo "laptop-control: $*" >&2; fail=1; };

# EPP: temporarily switch to powersave governor first because intel_pstate
# locks EPP writes when governor=performance
cpupower frequency-set -g powersave 2>/dev/null || mark_fail 'temporary governor powersave failed';

# EPP all cores
for c in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -w "$c/cpufreq/energy_performance_preference" ] || continue
    cur=$(cat "$c/cpufreq/energy_performance_preference" 2>/dev/null || echo unknown)
    [ "$cur" = "$B_EPP" ] || echo "$B_EPP" > "$c/cpufreq/energy_performance_preference" 2>/dev/null || mark_fail "EPP $B_EPP failed for ${c##*/}"
done;

# Power profile daemon must be switched after leaving performance governor
if command -v powerprofilesctl >/dev/null 2>&1; then
    cur=$(powerprofilesctl get 2>/dev/null || echo unknown)
    [ "$cur" = "$B_DAEMON" ] || powerprofilesctl set "$B_DAEMON" 2>/dev/null || mark_fail "daemon profile $B_DAEMON failed"
fi;

# Turbo
echo "$B_TURBO" > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || mark_fail 'turbo setting failed';

# Re-apply final EPP after daemon switch
cpupower frequency-set -g powersave 2>/dev/null || mark_fail 'pre-final governor powersave failed';
for c in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -w "$c/cpufreq/energy_performance_preference" ] || continue
    cur=$(cat "$c/cpufreq/energy_performance_preference" 2>/dev/null || echo unknown)
    [ "$cur" = "$B_EPP" ] || echo "$B_EPP" > "$c/cpufreq/energy_performance_preference" 2>/dev/null || mark_fail "final EPP $B_EPP failed for ${c##*/}"
done;

# CPU governor
cpupower frequency-set -g "$B_GOV" 2>/dev/null || mark_fail "governor $B_GOV failed";

# GPU PCI power control
for g in "$B_NV_CTRL" "$B_INT_CTRL"; do
    [ -f "$g" ] && echo "$B_GPUPM" > "$g" 2>/dev/null || true
done

# RAPL limits
for zone in /sys/class/powercap/intel-rapl:0 /sys/class/powercap/intel-rapl-mmio:0; do
    [ -d "$zone" ] || continue
    for i in 0 1 2; do
        nf="$zone/constraint_${i}_name"
        lf="$zone/constraint_${i}_power_limit_uw"
        [ -f "$nf" ] || continue
        name=$(cat "$nf" 2>/dev/null)
        [ "$name" = "long_term"  ] && echo "$B_PL1" > "$lf" 2>/dev/null || true
        [ "$name" = "short_term" ] && echo "$B_PL2" > "$lf" 2>/dev/null || true
    done
done

# Fix scaling_max_freq — must be AFTER daemon + turbo + governor + RAPL
# B_TURBO=0 means no_turbo=0 (Turbo ENABLED) -> target full boost freq
# B_TURBO=1 means no_turbo=1 (Turbo DISABLED) -> cap at base freq
if [ "$B_TURBO" = "0" ]; then
    target_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo 0)
else
    target_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/base_frequency 2>/dev/null || echo 0)
fi;

if [ "${target_freq:-0}" -gt 0 ]; then
    cpupower frequency-set -u "$target_freq" 2>/dev/null || true
    for p in /sys/devices/system/cpu/cpufreq/policy[0-9]* /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
        [ -w "$p/scaling_max_freq" ] || continue
        echo "$target_freq" > "$p/scaling_max_freq" 2>/dev/null || true
    done
fi;

# Verification
if command -v powerprofilesctl >/dev/null 2>&1; then
    cur=$(powerprofilesctl get 2>/dev/null || echo unknown)
    [ "$cur" = "$B_DAEMON" ] || mark_fail "daemon verification failed: expected $B_DAEMON, got $cur"
fi;
cur=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown); [ "$cur" = "$B_GOV" ] || mark_fail "governor verification failed: expected $B_GOV, got $cur";
cur=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo unknown); [ "$cur" = "$B_EPP" ] || mark_fail "EPP verification failed: expected $B_EPP, got $cur";
cur=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo unknown); [ "$cur" = "$B_TURBO" ] || mark_fail "turbo verification failed: expected $B_TURBO, got $cur";
EOF
}

fmt_change() {
    local current="$1" target="$2"
    if [ "$current" = "$target" ]; then
        printf '%s (same)' "$target"
    else
        printf '%s -> %s' "$current" "$target"
    fi
}

current_rapl_limit() {
    local wanted="$1" zone i nf lf name val
    for zone in /sys/class/powercap/intel-rapl:0 /sys/class/powercap/intel-rapl-mmio:0; do
        [ -d "$zone" ] || continue
        for i in 0 1 2; do
            nf="$zone/constraint_${i}_name"
            lf="$zone/constraint_${i}_power_limit_uw"
            [ -r "$nf" ] && [ -r "$lf" ] || continue
            name=$(cat "$nf" 2>/dev/null || echo "")
            if [ "$name" = "$wanted" ]; then
                val=$(cat "$lf" 2>/dev/null || echo 0)
                awk -v v="$val" 'BEGIN {printf "%.0fW", v/1000000}'
                return
            fi
        done
    done
    printf 'unknown'
}

current_gpu_limit() {
    if ! command -v nvidia-smi &>/dev/null; then echo "0"; return; fi
    timeout 1 nvidia-smi -q -d POWER 2>/dev/null | grep "Current Power Limit" | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1 || echo "0"
}

apply_profile() {
    local label="$1" gpu_perf_arg="$2"
    local pwr_daemon="$3" gov="$4" epp="$5"
    local turbo_val="$6" gpu_pm="$7"
    local pl1_uw="$8" pl2_uw="$9"
    shift 9
    local extra_root="$*"  # any extra root commands

    local cur_daemon cur_gov cur_epp cur_turbo cur_gpu_pm cur_pl1 cur_pl2 cur_gpu_lim
    init_gpu_vars
    cur_daemon=$(powerprofilesctl get 2>/dev/null || echo "unknown")
    cur_gov=$(cat "$CPU_BASE/cpu0/cpufreq/scaling_governor" 2>/dev/null || echo "unknown")
    cur_epp=$(cat "$CPU_BASE/cpu0/cpufreq/energy_performance_preference" 2>/dev/null || echo "unknown")
    cur_turbo=$(cat "$TURBO_PATH" 2>/dev/null || echo "unknown")
    cur_gpu_pm=$(cat "$NVIDIA_POWER_CTRL" 2>/dev/null || echo "unknown")
    cur_pl1=$(current_rapl_limit long_term)
    cur_pl2=$(current_rapl_limit short_term)
    cur_gpu_lim=$(current_gpu_limit)

    local target_turbo target_pl1 target_pl2 target_gpu_lim
    target_turbo=$([ "$turbo_val" = "0" ] && echo "0" || echo "1")
    target_pl1=$(awk "BEGIN {printf \"%.0fW\", $pl1_uw/1000000}")
    target_pl2=$(awk "BEGIN {printf \"%.0fW\", $pl2_uw/1000000}")
    target_gpu_lim=$([ "$gpu_perf_arg" -ge 2 ] && echo "100" || echo "70")

    local detail
    detail="Profile: $label\n"
    detail+="\n"
    detail+="── Current -> Target ──\n"
    detail+="  Daemon:         $(fmt_change "$cur_daemon" "$pwr_daemon")\n"
    detail+="  Governor:       $(fmt_change "$cur_gov" "$gov")\n"
    detail+="  EPP:            $(fmt_change "$cur_epp" "$epp")\n"
    detail+="  Turbo flag:     $(fmt_change "$cur_turbo" "$target_turbo")\n"
    detail+="  GPU PCI power:  $(fmt_change "$cur_gpu_pm" "$gpu_pm")\n"
    detail+="  CPU PL1 (Long): $(fmt_change "$cur_pl1" "$target_pl1")\n"
    detail+="  CPU PL2 (Short):$(fmt_change "$cur_pl2" "$target_pl2")\n"
    detail+="  GPU Watt Limit: $(fmt_change "${cur_gpu_lim}W" "${target_gpu_lim}W")\n"
    detail+="\n"
    detail+="── GPU Info ──\n"
    detail+="  EC profile:     $(case "$gpu_perf_arg" in 0) echo "quiet";; 1) echo "standard";; 2) echo "performance";; 3) echo "turbo";; esac)\n"
    detail+="  Under load:     $([ "$gpu_perf_arg" -ge 2 ] && echo "P0 state, up to 100W" || echo "P8-P2 state, 70W cap")\n"
    detail+="\n"
    detail+="── System ──\n"
    detail+="  Keyboard:       set to profile color\n"

    if ! whiptail --title "Apply Profile" --yesno "$detail" 24 76 3>&1 1>&2 2>&3; then
        return
    fi

    # Step 1: GPU EC profile (handles its own sudo internally)
    if [ -x "$GPU_PERF" ]; then
        local gpu_output
        if ! gpu_output=$("$GPU_PERF" "$gpu_perf_arg" 2>&1); then
            # Only show warning if there's actual ERROR: prefix (from die()) — not for
            # expected non-fatal notes from nvidia-smi (blocked -pl on modern drivers).
            if grep -qi "^ERROR:" <<< "$gpu_output"; then
                msg "Warning" "GPU profile step had issues.\n\n${gpu_output}"
            fi
        fi
        sleep 0.5
    else
        msg "Error" "gpu-perf.sh not found at:\n$GPU_PERF"
        return
    fi

    # Step 2: Batch all settings via single sudo (includes powerprofilesctl, governor, EPP, RAPL, turbo, GPU PCI)
    local batch
    batch=$(profile_batch)
    batch+="$extra_root"
    batch+="exit \$fail; "

    local apply_output
    if apply_output=$(sudo env \
        B_DAEMON="$pwr_daemon" \
        B_GOV="$gov" \
        B_EPP="$epp" \
        B_TURBO="$turbo_val" \
        B_GPUPM="$gpu_pm" \
        B_PL1="$pl1_uw" \
        B_PL2="$pl2_uw" \
        B_NV_CTRL="$NVIDIA_POWER_CTRL" \
        B_INT_CTRL="$INTEL_POWER_CTRL" \
        bash -c "$batch" 2>&1); then
        local _gpl
        _gpl=$(timeout 1 nvidia-smi -q -d POWER 2>/dev/null | grep "Current Power Limit" | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "")
        if [ -n "$_gpl" ]; then
            msg "Applied" "Profile '$label' applied.\nPower limit: ${_gpl}W"
        else
            msg "Applied" "Profile '$label' applied."
        fi
    else
        msg "Error" "Some settings did not apply or verify.\n\n${apply_output:-Auth may have been cancelled.}"
    fi
}

# -------------------------------------------------------
# 1. Performance Max with GPU (100W)
# -------------------------------------------------------
profile_perf_gpu() {
    # Re-enable NVIDIA GPU if it was powered off (PCI rescan)
    if ! lspci | grep -qi nvidia; then
        nvidia_gpu_on 2>/dev/null || true
    fi
    local extra="
# Keyboard: full red for max+gpu mode
echo 255 0 0 > /sys/class/leds/rgb:kbd_backlight/multi_intensity 2>/dev/null || true
echo 255 > /sys/class/leds/rgb:kbd_backlight/brightness 2>/dev/null || true
"
    apply_profile \
        "Performance Max + GPU" \
        "2"           "performance" "performance" "performance" \
        "0"           "on" \
        "45000000"    "115000000" \
        "$extra"
}

# -------------------------------------------------------
# 2. Performance Max (no GPU — 70W stock)
# -------------------------------------------------------
profile_perf_cpu() {
    # Re-enable NVIDIA GPU if it was powered off (PCI rescan)
    if ! lspci | grep -qi nvidia; then
        nvidia_gpu_on 2>/dev/null || true
    fi
    local extra="
# Keyboard: full orange for perf (no GPU unlock)
echo 255 128 0 > /sys/class/leds/rgb:kbd_backlight/multi_intensity 2>/dev/null || true
echo 255 > /sys/class/leds/rgb:kbd_backlight/brightness 2>/dev/null || true
"
    apply_profile \
        "Performance CPU Only" \
        "1"           "performance" "performance" "performance" \
        "0"           "on" \
        "45000000"    "115000000" \
        "$extra"
}

# -------------------------------------------------------
# 3. Balanced
# -------------------------------------------------------
profile_balanced() {
    # Re-enable NVIDIA GPU if it was powered off (PCI rescan)
    if ! lspci | grep -qi nvidia; then
        nvidia_gpu_on 2>/dev/null || true
    fi
    local extra="
# Keyboard: white for balanced
echo 255 255 255 > /sys/class/leds/rgb:kbd_backlight/multi_intensity 2>/dev/null || true
echo 128 > /sys/class/leds/rgb:kbd_backlight/brightness 2>/dev/null || true
"
    apply_profile \
        "Balanced" \
        "0"           "balanced" "powersave" "balance_performance" \
        "0"           "on" \
        "40000000"    "80000000" \
        "$extra"
}

# -------------------------------------------------------
# 4. Powersave
# -------------------------------------------------------
profile_powersave() {
    local extra="
# Keyboard: green + dim for powersave
echo 0 255 0 > /sys/class/leds/rgb:kbd_backlight/multi_intensity 2>/dev/null || true
echo 32 > /sys/class/leds/rgb:kbd_backlight/brightness 2>/dev/null || true
"
    apply_profile \
        "Powersave" \
        "0"           "power-saver" "powersave" "power" \
        "1"           "auto" \
        "30000000"    "35000000" \
        "$extra"
}

# -------------------------------------------------------
# 5. Ultra Powersave (15W/25W)
# -------------------------------------------------------
profile_powersave_ultra() {
    local extra="
# Keyboard: very dim teal for ultra powersave
echo 0 64 64 > /sys/class/leds/rgb:kbd_backlight/multi_intensity 2>/dev/null || true
echo 16 > /sys/class/leds/rgb:kbd_backlight/brightness 2>/dev/null || true
"
    apply_profile \
        "Ultra Powersave" \
        "0"           "power-saver" "powersave" "power" \
        "1"           "auto" \
        "15000000"    "25000000" \
        "$extra"
}

# ============================================================
# INDIVIDUAL CPU TWEAKS
# ============================================================

apply_rapl() {
    if [ -x "$PL_SCRIPT" ]; then
        "$PL_SCRIPT" apply 2>&1 || msg "Error" "Failed to apply limits via pl.sh."
        return
    fi
    run_root "Apply 40W/80W" '
        for zone in /sys/class/powercap/intel-rapl:0 /sys/class/powercap/intel-rapl-mmio:0; do
            [ -d "$zone" ] || continue
            for i in 0 1 2; do
                nf="$zone/constraint_${i}_name"
                lf="$zone/constraint_${i}_power_limit_uw"
                [ -f "$nf" ] || continue
                name=$(cat "$nf" 2>/dev/null)
                if [ "$name" = "long_term" ]; then  echo 40000000 > "$lf" 2>/dev/null || true; fi
                if [ "$name" = "short_term" ]; then echo 80000000 > "$lf" 2>/dev/null || true; fi
            done
        done
    '
}

restore_rapl() {
    if [ -x "$PL_SCRIPT" ]; then
        "$PL_SCRIPT" restore 2>&1 || msg "Error" "Restore failed."
    else
        msg "Info" "pl.sh not found — no saved state available."
    fi
}

set_gov() {
    run_root "Governor: $1" "cpupower frequency-set -g $1"
}

set_turbo() {
    local label="enable"
    [ "$1" = "1" ] && label="disable"
    run_root "Turbo: $label" "echo $1 > /sys/devices/system/cpu/intel_pstate/no_turbo"
}

epp_menu() {
    local choice
    choice=$(whiptail --title "EPP" \
        --menu "Energy Performance Preference" 12 50 4 \
        "performance"         "Maximum performance" \
        "balance_performance" "Balanced performance" \
        "balance_power"       "Balanced power saving" \
        "power"               "Maximum power saving" \
        3>&1 1>&2 2>&3) || return
    [ -z "$choice" ] && return

    # intel_pstate locks EPP writes when governor=performance, so
    # temporarily switch to powersave first, then restore original.
    local cmd
    cmd="cur_gov=\$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown); "
    cmd+="cpupower frequency-set -g powersave 2>/dev/null || true; "
    for core in /sys/devices/system/cpu/cpu[0-9]*; do
        cmd+="echo $choice > $core/cpufreq/energy_performance_preference 2>/dev/null || true; "
    done
    cmd+="cpupower frequency-set -g \"\$cur_gov\" 2>/dev/null || true; "
    run_root "EPP: $choice" "$cmd"
}

set_gpu_pm() {
    init_gpu_vars
    local val="$1" label="$2"
    local cmds=""
    for g in "$NVIDIA_POWER_CTRL" "$INTEL_POWER_CTRL"; do
        [ -f "$g" ] && cmds+="echo $val > $g; "
    done
    run_root "GPU power: $label" "$cmds"
}

set_gpu_power_limit() {
    local watts="$1"
    if ! command -v nvidia-smi &>/dev/null; then
        msg "Error" "nvidia-smi not available."
        return
    fi
    if ! confirm "GPU Power Limit" "Set GPU power limit to ${watts}W?\n\nEnsure this is within the supported range (check nvidia-smi -q -d POWER)"; then
        return
    fi
    if sudo nvidia-smi -pl "$watts" 2>/dev/null; then
        msg "GPU Limit" "GPU power limit set to ${watts}W"
    else
        msg "Error" "Failed to set ${watts}W GPU limit.\nCheck nvidia-smi for supported range."
    fi
}

cpu_tweaks_menu() {
    while true; do
        local choice
        choice=$(whiptail --title "CPU & GPU Tweaks" \
            --menu "Individual adjustments" 16 60 10 \
            "1"  "Power Limits: apply 40W/80W" \
            "2"  "Power Limits: restore defaults" \
            "3"  "Governor: performance" \
            "4"  "Governor: powersave" \
            "5"  "Turbo Boost: enable" \
            "6"  "Turbo Boost: disable" \
            "7"  "Set EPP" \
            "8"  "GPU PCI power: max perf (on)" \
            "9"  "GPU PCI power: auto (efficient)" \
            "10" "Set GPU power limit (custom W)" \
            "11" "Back to main" \
            3>&1 1>&2 2>&3) || break
        [ -z "$choice" ] || [ "$choice" = "11" ] && break
        case "$choice" in
            1) apply_rapl ;;
            2) restore_rapl ;;
            3) set_gov "performance" ;;
            4) set_gov "powersave" ;;
            5) set_turbo 0 ;;
            6) set_turbo 1 ;;
            7) epp_menu ;;
            8) set_gpu_pm "on"   "max perf" ;;
            9) set_gpu_pm "auto" "efficient" ;;
            10)
                local watts
                watts=$(inputbox "GPU Power Limit" "Enter power limit in watts (e.g. 40, 70, 100):" "70") || continue
                [[ "$watts" =~ ^[0-9]+$ ]] && set_gpu_power_limit "$watts" || msg "Error" "Invalid number."
                ;;
        esac
    done
}

# ============================================================
# KEYBOARD BACKLIGHT
# ============================================================

kbd_available() {
    [ -d "$LED_PATH" ]
}

kbd_menu() {
    if ! kbd_available; then
        msg "Keyboard" "LED zone not available.\nLoad tuxedo_keyboard with force_backlight_type=6:\nsudo modprobe tuxedo_keyboard force_backlight_type=6"
        return
    fi

    local breathe_status="Start breathing"
    if [ -f "$BREATHE_PID_FILE" ]; then
        local old_pid=$(cat "$BREATHE_PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            # Verify it's actually our script and not a recycled PID
            if ps -p "$old_pid" -o comm= | grep -qE "kbd-breathing|bash|sh"; then
                breathe_status="Stop breathing (running)"
            fi
        fi
    fi

    while true; do
        local cur_bri=$(cat "$LED_PATH/brightness" 2>/dev/null || echo "0")
        local cur_col=$(cat "$LED_PATH/multi_intensity" 2>/dev/null || echo "???")
        local choice
        
        choice=$(whiptail --title "Keyboard Backlight" \
            --menu "Current: Brightness $cur_bri | RGB [$cur_col]\nEffect: $breathe_status" 18 60 8 \
            "1" "Set color (presets)" \
            "2" "Set color (custom hex)" \
            "3" "Brightness: low (64)" \
            "4" "Brightness: medium (128)" \
            "5" "Brightness: high (255)" \
            "6" "Toggle Breathing effect" \
            "7" "Turn off" \
            "8" "Back to main" \
            3>&1 1>&2 2>&3) || break
        { [ -z "$choice" ] || [ "$choice" = "8" ]; } && break
        case "$choice" in
            1) color_presets ;;
            2) color_custom ;;
            3) kbd_set_brightness 64 ;;
            4) kbd_set_brightness 128 ;;
            5) kbd_set_brightness 255 ;;
            6) toggle_breathing ;;
            7) kbd_set_brightness 0 ;;
        esac
        
        breathe_status="Start breathing"
        if [ -f "$BREATHE_PID_FILE" ]; then
            local check_pid=$(cat "$BREATHE_PID_FILE")
            if kill -0 "$check_pid" 2>/dev/null && ps -p "$check_pid" -o comm= | grep -qE "kbd-breathing|bash|sh"; then
                breathe_status="Stop breathing (running)"
            fi
        fi
    done
}

kbd_set_brightness() {
    local bri="$1"
    kbd_write "$LED_PATH/brightness" "$bri"
    if [ "$bri" -gt 0 ]; then
        msg "Keyboard" "Brightness set to $bri"
    else
        msg "Keyboard" "Keyboard lights off"
    fi
}

kbd_set_color() {
    local hex="$1"
    local r=$((16#${hex:0:2}))
    local g=$((16#${hex:2:2}))
    local b=$((16#${hex:4:2}))
    kbd_write "$LED_PATH/multi_intensity" "$r $g $b"
    msg "Keyboard" "Color set to #${hex}"
}

color_presets() {
    local choice hex
    choice=$(whiptail --title "Keyboard Color" \
        --menu "Choose a color:" 18 40 12 \
        "white"   "FFFFFF — Default" \
        "red"     "FF0000" \
        "green"   "00FF00" \
        "blue"    "0000FF" \
        "yellow"  "FFFF00" \
        "cyan"    "00FFFF" \
        "magenta" "FF00FF" \
        "orange"  "FF8000" \
        "purple"  "8000FF" \
        "pink"    "FF0080" \
        "lime"    "80FF00" \
        "teal"    "008080" \
        3>&1 1>&2 2>&3) || return
    [ -z "$choice" ] && return

    case "$choice" in
        white)   hex="FFFFFF" ;; red)    hex="FF0000" ;;
        green)   hex="00FF00" ;; blue)   hex="0000FF" ;;
        yellow)  hex="FFFF00" ;; cyan)   hex="00FFFF" ;;
        magenta) hex="FF00FF" ;; orange) hex="FF8000" ;;
        purple)  hex="8000FF" ;; pink)   hex="FF0080" ;;
        lime)    hex="80FF00" ;; teal)   hex="008080" ;;
    esac
    kbd_set_color "$hex"
    kbd_set_brightness 255
}

color_custom() {
    local hex
    hex=$(inputbox "Custom Color" "Enter RRGGBB hex (e.g. ff4500):" "ffffff") || return
    [ -z "$hex" ] && return
    if ! [[ "$hex" =~ ^[0-9a-fA-F]{6}$ ]]; then
        msg "Error" "Invalid color: $hex\nMust be 6 hex digits (RRGGBB)."
        return
    fi
    kbd_set_color "$hex"
    kbd_set_brightness 255
}

toggle_breathing() {
    local old_pid=""
    [ -f "$BREATHE_PID_FILE" ] && old_pid=$(cat "$BREATHE_PID_FILE")

    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        # Verify it's actually our script before killing
        if ps -p "$old_pid" -o comm= | grep -qE "kbd-breathing|bash|sh"; then
            kill "$old_pid" 2>/dev/null || true
            sleep 0.3
            kill -0 "$old_pid" 2>/dev/null && kill -9 "$old_pid" 2>/dev/null || true
            rm -f "$BREATHE_PID_FILE"
            sleep 0.3
            kbd_write "$LED_PATH/brightness" "255"
            msg "Breathing" "Breathing effect stopped."
            return
        else
            # Stale PID file for a different process
            rm -f "$BREATHE_PID_FILE"
        fi
    fi

    rm -f "$BREATHE_PID_FILE"

    local mode
    mode=$(whiptail --title "Breathing" --menu "Select mode:" 12 40 3 \
        "static"     "Single color breathing" \
        "rainbow"    "Rainbow hue cycling" \
        "colorcycle" "Custom color cycle" \
        3>&1 1>&2 2>&3) || return
    [ -z "$mode" ] && return

    local args=()
    case "$mode" in
        static)
            local hex
            hex=$(inputbox "Breathing Color" "Enter RRGGBB hex:" "ff0000") || return
            [ -z "$hex" ] || ! [[ "$hex" =~ ^[0-9a-fA-F]{6}$ ]] && return
            args=(-c "$hex")
            ;;
        rainbow)
            args=(-r)
            ;;
        colorcycle)
            local colors
            colors=$(inputbox "Color Cycle" "Comma-separated RRGGBB colors:\ne.g. ff0000,00ff00,0000ff" "ff0000,00ff00,0000ff") || return
            [ -z "$colors" ] && return
            if ! [[ "$colors" =~ ^[0-9a-fA-F]{6}(,[0-9a-fA-F]{6})+$ ]]; then
                msg "Error" "Invalid color cycle.\nUse comma-separated RRGGBB colors."
                return
            fi
            args=(-C "$colors")
            ;;
    esac

    "$KBD_BREATHING" "${args[@]}" >/dev/null 2>&1 &
    local pid=$!
    echo "$pid" > "$BREATHE_PID_FILE"
    disown "$pid" 2>/dev/null || true
    msg "Breathing" "Started in background.\nStop it from the keyboard menu."
}

# ============================================================
# SYSTEM STATUS
# ============================================================

show_status() {
    local temp="N/A" gov="N/A" epp="N/A" turbo="N/A"
    local max_f="N/A" pl1="N/A" pl2="N/A"
    local gpu_temp="--" gpu_load="--" gpu_vram="--" gpu_vram_total="--" gpu_pwr="--"
    local mem_used="--" mem_total="--"
    local pwr_profile="N/A"
    local gpu_pstate="--" gpu_pwr_limit="--"
    local zone ttype mf tv nf lf name val mf_val bf_val active_profile body
    local gpu_data profile_hint="standard"
    local max_freq_file="/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq"
    local base_freq_file="/sys/devices/system/cpu/cpu0/cpufreq/base_frequency"
    local turbo_max="N/A"

    # CPU temperature — prefer x86_pkg_temp (package temp) over cpu-thermal
    for zone in /sys/class/thermal/thermal_zone*; do
        [ -r "$zone/type" ] && [ -r "$zone/temp" ] || continue
        ttype=$(cat "$zone/type" 2>/dev/null || echo "")
        if [ "$ttype" = "x86_pkg_temp" ]; then
            temp=$(($(cat "$zone/temp" 2>/dev/null || echo 0) / 1000))
            break
        fi
    done
    # Fallback to cpu-thermal if x86_pkg_temp was not found
    if [ "$temp" = "N/A" ]; then
        for zone in /sys/class/thermal/thermal_zone*; do
            [ -r "$zone/type" ] && [ -r "$zone/temp" ] || continue
            ttype=$(cat "$zone/type" 2>/dev/null || echo "")
            if [ "$ttype" = "cpu-thermal" ]; then
                temp=$(($(cat "$zone/temp" 2>/dev/null || echo 0) / 1000))
                break
            fi
        done
    fi

    # Governor, EPP, max freq
    if [ -d "$CPU_BASE/cpu0/cpufreq" ]; then
        gov=$(cat "$CPU_BASE/cpu0/cpufreq/scaling_governor" 2>/dev/null || echo "N/A")
        epp=$(cat "$CPU_BASE/cpu0/cpufreq/energy_performance_preference" 2>/dev/null || echo "N/A")
        mf=$(cat "$CPU_BASE/cpu0/cpufreq/scaling_max_freq" 2>/dev/null || echo 0)
        max_f=$(awk -v v="$mf" 'BEGIN {printf "%.2f GHz", v/1000000}')
    fi

    # Turbo
    if [ -f "$TURBO_PATH" ]; then
        tv=$(cat "$TURBO_PATH" 2>/dev/null || echo "0")
        if [ "$tv" = "0" ]; then turbo="ON"; else turbo="OFF"; fi
    fi

    # RAPL
    for zone in /sys/class/powercap/intel-rapl:0 /sys/class/powercap/intel-rapl-mmio:0; do
        [ -d "$zone" ] || continue
        for i in 0 1 2; do
            nf="$zone/constraint_${i}_name"
            lf="$zone/constraint_${i}_power_limit_uw"
            [ -r "$nf" ] || continue
            name=$(cat "$nf" 2>/dev/null || echo "")
            val=$(cat "$lf" 2>/dev/null || echo 0)
            if [ "$name" = "long_term" ]; then
                pl1=$(awk -v v="$val" 'BEGIN {printf "%.1fW", v/1000000}')
            fi
            if [ "$name" = "short_term" ]; then
                pl2=$(awk -v v="$val" 'BEGIN {printf "%.1fW", v/1000000}')
            fi
        done
    done

    # RAM
    read -r mem_total mem_used < <(awk '/^MemTotal:/  {t=$2} /^MemAvailable:/ {a=$2} END {printf "%.0f %.0f\n", t/1048576, (t-a)/1048576}' /proc/meminfo 2>/dev/null) || true

    # Power profile daemon
    if command -v powerprofilesctl &>/dev/null; then
        pwr_profile=$(powerprofilesctl get 2>/dev/null || echo "N/A")
    fi

    # GPU
    if command -v nvidia-smi &>/dev/null; then
        gpu_data=$(timeout 1.5 nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,memory.used,memory.total,power.draw --format=csv,noheader,nounits 2>/dev/null || true)
        if [ -n "$gpu_data" ]; then
            IFS=', ' read -r gpu_temp gpu_load gpu_vram gpu_vram_total gpu_pwr <<< "$gpu_data"
        fi
        # GPU P-state (P0/P2/P8/P12)
        gpu_pstate=$(timeout 1 nvidia-smi -q -d PERFORMANCE 2>/dev/null | grep "Performance State" | head -1 | grep -oE 'P[0-9]+' || echo "--")
        # GPU power limit — use verbose query: --query-gpu=power.limit returns [N/A] in P8 idle
        gpu_pwr_limit=$(timeout 1 nvidia-smi -q -d POWER 2>/dev/null | grep "Current Power Limit" | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "--")
        # pipefail can prevent the || fallback from triggering when nvidia-smi times out
        [ -z "$gpu_pwr_limit" ] && gpu_pwr_limit="--"
    fi

    # Detect GPU profile based on power limit
    # The EC only supports: capped (70W, quiet/standard) and unlocked (100W, perf/turbo)
    if command -v nvidia-smi &>/dev/null && [ "$gpu_pwr_limit" != "--" ]; then
        if awk "BEGIN {exit !($gpu_pwr_limit >= 75)}" 2>/dev/null; then
            profile_hint="performance/turbo"
        else
            profile_hint="quiet/standard"
        fi
    fi

    # Max turbo frequency
    if [ -f "$max_freq_file" ]; then
        mf_val=$(cat "$max_freq_file" 2>/dev/null || echo 0)
        if [ "$mf_val" -gt 0 ]; then
            bf_val=""
            [ -f "$base_freq_file" ] && bf_val=$(cat "$base_freq_file" 2>/dev/null || echo "")
            if [ -n "$bf_val" ] && [ "$bf_val" -gt 0 ] && [ "$mf_val" -gt "$bf_val" ]; then
                turbo_max=$(awk -v m="$mf_val" -v b="$bf_val" 'BEGIN {printf "%.1f/%.1f GHz", b/1000000, m/1000000}')
            else
                turbo_max=$(awk -v v="$mf_val" 'BEGIN {printf "%.1f GHz", v/1000000}')
            fi
        fi
    fi

    local raw_pwr
    raw_pwr=$(timeout 0.7 nvidia-smi -q -d POWER 2>/dev/null | grep "Current Power Limit" | grep -oE '[0-9]+' | head -1 || echo "0")
    raw_pwr="${raw_pwr:-0}"
    [[ "$raw_pwr" =~ ^[0-9]+$ ]] || raw_pwr=0
    active_profile=$(get_active_profile_name "$raw_pwr")

    body="Active Profile:    ${active_profile}\n"
    body+="───────────────────────────────────────\n"
    body+="CPU Temperature:   ${temp}°C\n"
    body+="Daemon Profile:   ${pwr_profile}\n"
    body+="Governor:         ${gov}\n"
    body+="EPP:              ${epp}\n"
    body+="Turbo Boost:      ${turbo}\n"
    body+="Max Frequency:    ${max_f}\n"
    body+="CPU Power Limits: PL1 ${pl1}  PL2 ${pl2}\n"
    body+="\n"
    body+="RAM:              ${mem_used}G / ${mem_total}G\n"
    body+="\n"
    body+="NVIDIA RTX 4060:\n"
    body+="  Temp: ${gpu_temp}°C  |  Load: ${gpu_load}%\n"
    body+="  VRAM: ${gpu_vram:-0}/${gpu_vram_total:-0} MiB  |  ${gpu_pwr:-0}W\n"
    body+="  P-State: ${gpu_pstate}  |  Limit: ${gpu_pwr_limit}$([ "$gpu_pwr_limit" = "--" ] || echo "W")  |  ${profile_hint}\n"
    body+="\n"
    body+="Kernel: $(uname -r)"

    whiptail --title "System Status" --msgbox "$body" 24 65 3>&1 1>&2 2>&3
}

# ============================================================
# UI HELPERS
# ============================================================

get_sys_summary() {
    local gpu_pwr="${1:-0}"
    local active_profile
    active_profile=$(get_active_profile_name "$gpu_pwr")
    printf "Current Profile: %s" "$active_profile"
}

is_profile_active() {
    local target_gov="$1" target_epp="$2" target_turbo="$3"
    local target_gpu_pwr="${4:-}"
    local cur_gpu_pwr="${5:-0}"
    local pl1_min_uw="${6:-}"   # optional: min PL1 in µW
    local pl1_max_uw="${7:-}"   # optional: max PL1 in µW
    # Sanitize — nvidia-smi can return [N/A] instead of a number
    if ! [[ "$cur_gpu_pwr" =~ ^[0-9]+$ ]]; then cur_gpu_pwr=0; fi
    local cur_gov cur_epp cur_turbo
    cur_gov=$(cat "$CPU_BASE/cpu0/cpufreq/scaling_governor" 2>/dev/null || echo "")
    cur_epp=$(cat "$CPU_BASE/cpu0/cpufreq/energy_performance_preference" 2>/dev/null || echo "")
    cur_turbo=$(cat "$TURBO_PATH" 2>/dev/null || echo "")
    
    if [ "$cur_gov" = "$target_gov" ] && [ "$cur_epp" = "$target_epp" ] && [ "$cur_turbo" = "$target_turbo" ]; then
        # Check GPU power limit to disambiguate performance profiles
        if [ -n "$target_gpu_pwr" ]; then
            if [ "$target_gpu_pwr" -eq 100 ]; then
                # For 100W profile, allow 80W-100W range (P8/P5 idle vs P0 load)
                if (( cur_gpu_pwr < 80 )); then return 1; fi
            else
                # For standard/cpu profiles, expect stock 70W
                if [ "$cur_gpu_pwr" -ne "$target_gpu_pwr" ] && [ "$cur_gpu_pwr" -ne 0 ]; then return 1; fi
            fi
        fi
        # Check PL1 range to disambiguate profiles with same CPU settings
        if [ -n "$pl1_min_uw" ] || [ -n "$pl1_max_uw" ]; then
            local cur_pl1
            cur_pl1=$(for zone in /sys/class/powercap/intel-rapl:0 /sys/class/powercap/intel-rapl-mmio:0; do
                [ -d "$zone" ] || continue
                for i in 0 1 2; do
                    nf="$zone/constraint_${i}_name"
                    lf="$zone/constraint_${i}_power_limit_uw"
                    [ -r "$nf" ] && [ -r "$lf" ] || continue
                    [ "$(cat "$nf" 2>/dev/null)" = "long_term" ] || continue
                    cat "$lf" 2>/dev/null
                    exit 0
                done
            done || echo "0")
            cur_pl1="${cur_pl1//[!0-9]/}"
            cur_pl1="${cur_pl1:-0}"
            [ -n "$pl1_min_uw" ] && [ "$cur_pl1" -lt "$pl1_min_uw" ] 2>/dev/null && return 1
            [ -n "$pl1_max_uw" ] && [ "$cur_pl1" -gt "$pl1_max_uw" ] 2>/dev/null && return 1
        fi
        printf " *"
    fi
}

get_active_profile_name() {
    local gpu_pwr="${1:-0}"
    if [ -n "$(is_profile_active "performance" "performance" "0" "100" "$gpu_pwr")" ]; then
        echo "Performance Max + GPU (100W)"
    elif [ -n "$(is_profile_active "performance" "performance" "0" "70" "$gpu_pwr")" ]; then
        echo "Performance CPU Only"
    elif [ -n "$(is_profile_active "powersave" "balance_performance" "0" "" "$gpu_pwr")" ]; then
        echo "Balanced"
    elif [ -n "$(is_profile_active "powersave" "power" "1" "" "$gpu_pwr" "" "20000000")" ]; then
        echo "Ultra Powersave"
    elif [ -n "$(is_profile_active "powersave" "power" "1" "" "$gpu_pwr" "20000001")" ]; then
        echo "Powersave"
    else
        echo "Custom / Manual"
    fi
}

# ============================================================
# MAIN MENU
# ============================================================

main_menu() {
    while true; do
        # Cache slow values once per loop to keep UI snappy
        local cached_gpu_pwr="0"
        if command -v nvidia-smi &>/dev/null; then
            cached_gpu_pwr=$(timeout 0.5 nvidia-smi -q -d POWER 2>/dev/null | grep "Current Power Limit" | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1 || echo "0")
        fi

        local summary=$(get_sys_summary "$cached_gpu_pwr")
        local choice
        choice=$(whiptail --title "Colorful P15 Control Center" \
            --menu "$summary\n\nSelect a performance profile or tweak settings:" 24 65 11 \
            "1" "Performance Max + GPU (100W)$(is_profile_active "performance" "performance" "0" "100" "$cached_gpu_pwr")" \
            "2" "Performance CPU Only$(is_profile_active "performance" "performance" "0" "70" "$cached_gpu_pwr")" \
            "3" "Balanced$(is_profile_active "powersave" "balance_performance" "0" "" "$cached_gpu_pwr")" \
            "4" "Powersave$(is_profile_active "powersave" "power" "1" "" "$cached_gpu_pwr" "20000001")" \
            "5" "Ultra Powersave (15W/25W)$(is_profile_active "powersave" "power" "1" "" "$cached_gpu_pwr" "" "20000000")" \
            "6" "Custom Tweaks (CPU/GPU parts)" \
            "7" "Keyboard Backlight" \
            "8" "System Status (Detailed)" \
            "9" "Experimental: GPU PCI Control" \
            "10" "Quit" \
            3>&1 1>&2 2>&3) || choice="10"
        [ -z "$choice" ] && choice="10"
        case "$choice" in
            1) profile_perf_gpu ;;
            2) profile_perf_cpu ;;
            3) profile_balanced ;;
            4) profile_powersave ;;
            5) profile_powersave_ultra ;;
            6) cpu_tweaks_menu ;;
            7) kbd_menu ;;
            8) show_status ;;
            9) gpu_experimental_menu ;;
            10) break ;;
        esac
    done
}

# ============================================================
# ENTRY
# ============================================================

main_menu

