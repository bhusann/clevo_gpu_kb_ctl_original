#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# gpu-perf.sh — one-shot GPU performance profile switcher for Clevo P15 23
#
# Usage: ./gpu-perf.sh [profile]
#   profile: 0=quiet, 1=standard, 2=performance (default), 3=turbo
#
# Calls the Clevo _DSM function 0x79 (CLEVO_CMD_OPT) with sub-command 0x19
# to set the EC performance profile AND update GPU OpRegion power limits.

set -euo pipefail

# Debug trap: log unexpected non-zero exits for diagnostics
trap 'rc=$?; [ "$rc" -ne 0 ] && echo "gpu-perf: exit code $rc (last cmd: $BASH_COMMAND)" >&2' EXIT

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
MODULE_SRC_DIR="${SCRIPT_DIR}/modules"
MODULE_NAME="set_perf_profile"
MODULE_KO="${MODULE_SRC_DIR}/${MODULE_NAME}-$(uname -r).ko"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# Safe logger wrapper — no-op if logger(1) is unavailable; always returns 0 to
# protect against set -e crashes when syslog is not running.
log_msg() {
    command -v logger &>/dev/null && logger "$@" 2>/dev/null || true
}

# --- Root check & re-exec ---
if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

# --- Help request ---
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: $0 [PROFILE]"
    echo ""
    echo "Set GPU performance profile for Clevo P15 23 (and similar)."
    echo ""
    echo "PROFILE:"
    echo "  0  quiet       — low fan, stock power limits"
    echo "  1  standard    — balanced fan, stock power limits"
    echo "  2  performance — higher fan curve, GPU unlocked up to 100W (default)"
    echo "  3  turbo       — max fan curve, GPU unlocked up to 100W"
    echo ""
    echo "Examples:"
    echo "  $0          # set performance (2)"
    echo "  $0 0        # set quiet"
    echo "  $0 3        # set turbo"
    exit 0
fi

# --- Parse profile ---
PROFILE="${1:-2}"
case "${PROFILE}" in
    0) PNAME="quiet" ;;
    1) PNAME="standard" ;;
    2) PNAME="performance" ;;
    3) PNAME="turbo" ;;
    *) echo "Usage: $0 [0|1|2|3]"
       echo "  0 = quiet, 1 = standard, 2 = performance (default), 3 = turbo"
       exit 1 ;;
esac

# --- Check prerequisites ---
if ! command -v flock &>/dev/null; then
    die "flock not found. Please install 'util-linux' (Arch/CachyOS) or 'util-linux-core'."
fi

if ! command -v insmod &>/dev/null; then
    die "insmod not found. Please install 'kmod'."
fi

# --- Build module if needed ---
if [[ ! -f "${MODULE_KO}" ]]; then
    BUILD_PATH="/lib/modules/$(uname -r)/build"
    if [[ ! -d "${BUILD_PATH}" ]]; then
        die "Kernel build directory not found at ${BUILD_PATH}. Please install kernel headers (e.g., 'linux-cachyos-headers' or 'linux-headers')."
    fi

    # Determine compiler: CachyOS prefers clang, fallback to gcc
    if command -v clang &>/dev/null; then
        CC="clang"
        LD=$(command -v ld.lld &>/dev/null && echo "ld.lld" || echo "ld")
    else
        CC="gcc"
        LD="ld"
    fi
    mkdir -p "${MODULE_SRC_DIR}"
    (
        flock -x 200

        # Double check inside lock
        [[ -f "${MODULE_KO}" ]] && exit 0

        echo "==> Compiling kernel module for $(uname -r)..."
        
        MODULE_SRC="${MODULE_SRC_DIR}/${MODULE_NAME}.c"
        cat > "${MODULE_SRC}" << 'SOURCE_EOF'
// SPDX-License-Identifier: GPL-2.0-only
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/acpi.h>

#define CLEVO_DSM_UUID "93f224e4-fbdc-4bbf-add6-db71bdc0afad"

static int profile = 2;
module_param(profile, int, 0444);
MODULE_PARM_DESC(profile, "Performance profile: 0=quiet, 1=standard, 2=performance, 3=turbo");

static int __init set_perf_init(void)
{
    acpi_handle handle = NULL;
    acpi_status status;
    guid_t uuid;
    union acpi_object *out_obj;
    union acpi_object arg;
    union acpi_object package;
    u32 cmd_arg;
    const char *paths[] = {"\\_SB.DCHU", "\\_SB.PCI0.LPCB.EC0", NULL};
    int i;

    if (profile < 0 || profile > 3)
        return -EINVAL;

    for (i = 0; paths[i]; i++) {
        status = acpi_get_handle(NULL, (acpi_string)paths[i], &handle);
        if (ACPI_SUCCESS(status)) break;
    }

    if (!handle) {
        pr_err("gpu-perf: No valid ACPI handle found\n");
        return -ENODEV;
    }

    if (guid_parse(CLEVO_DSM_UUID, &uuid) != 0) {
        pr_err("gpu-perf: Invalid UUID format\n");
        return -EINVAL;
    }

    // Arg encoding: (sub_cmd << 24) | (data & 0xFFFFFF)
    // sub_cmd 0x19: set performance profile
    cmd_arg = (0x19 << 24) | (profile & 0xFFFFFF);
    arg.type = ACPI_TYPE_INTEGER;
    arg.integer.value = cmd_arg;

    package.type = ACPI_TYPE_PACKAGE;
    package.package.count = 1;
    package.package.elements = &arg;

    out_obj = acpi_evaluate_dsm(handle, &uuid, 0, 0x79, &package);
    if (!out_obj) {
        pr_err("gpu-perf: _DSM evaluate failed\n");
        return -EIO;
    }

    if (out_obj->type == ACPI_TYPE_INTEGER)
        pr_info("gpu-perf: _DSM (profile %d) returned 0x%llx\n", profile, out_obj->integer.value);
    
    ACPI_FREE(out_obj);
    return -EAGAIN; // One-shot: load, execute, auto-unload
}

module_init(set_perf_init);
MODULE_LICENSE("GPL");
MODULE_AUTHOR("turbo");
MODULE_DESCRIPTION("Clevo performance profile setter");
SOURCE_EOF

        echo "obj-m += ${MODULE_NAME}.o" > "${MODULE_SRC_DIR}/Makefile"

        BUILD_LOG=$(mktemp /tmp/gpu-perf-build.XXXXXX)
        if ! make -C "${BUILD_PATH}" M="${MODULE_SRC_DIR}" modules CC="${CC}" LD="${LD}" >"${BUILD_LOG}" 2>&1; then
            echo "--- Build Error ---" >&2
            cat "${BUILD_LOG}" >&2
            rm -f "${BUILD_LOG}"
            die "Module compilation failed."
        fi
        rm -f "${BUILD_LOG}"

        cp "${MODULE_SRC_DIR}/${MODULE_NAME}.ko" "${MODULE_KO}"

        # Clean up source and intermediate build artifacts
        rm -f "${MODULE_SRC}" \
              "${MODULE_SRC_DIR}/${MODULE_NAME}.o" \
              "${MODULE_SRC_DIR}/${MODULE_NAME}.mod.c" \
              "${MODULE_SRC_DIR}/${MODULE_NAME}.mod" \
              "${MODULE_SRC_DIR}/${MODULE_NAME}.mod.o" \
              "${MODULE_SRC_DIR}/Module.symvers" \
              "${MODULE_SRC_DIR}/modules.order"
        # Clean up generated .cmd files
        rm -f "${MODULE_SRC_DIR}/.${MODULE_NAME}.o.cmd" \
              "${MODULE_SRC_DIR}/.${MODULE_NAME}.ko.cmd" \
              "${MODULE_SRC_DIR}/.${MODULE_NAME}.mod.o.cmd" 2>/dev/null || true

        echo "==> Compiled successfully for $(uname -r)."
    ) 200>"${MODULE_SRC_DIR}/.build.lock" || exit 1
fi

# --- Prune old modules ---
if [[ -d "${MODULE_SRC_DIR}" ]] && [[ "${MODULE_SRC_DIR}" == "${SCRIPT_DIR}/modules" ]]; then
    find "${MODULE_SRC_DIR}" -name "${MODULE_NAME}-*.ko" ! -name "${MODULE_NAME}-$(uname -r).ko" -delete
fi

# --- Current state check ---
get_power_limit() {
    if ! command -v nvidia-smi &>/dev/null; then echo "0"; return; fi
    local val
    # Use timeout to prevent hanging; 2>/dev/null suppresses stderr even if nvidia-smi is slow
    val=$(timeout 3 LC_ALL=C nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null | head -1 | cut -d. -f1 || echo "0")
    # Strip non-numeric characters (e.g. [N/A] → 0)
    val="${val//[!0-9]/}"
    echo "${val:-0}"
}

TARGET_W=$([[ "${PROFILE}" -ge 2 ]] && echo "100" || echo "70")

# --- Load module ---
# insmod returns 0 (success) or 1 (failure). For our one-shot module,
# the kernel returns -EAGAIN, which insmod reports as a failure with a specific message.
# We force LC_ALL=C to ensure stable string parsing across different locales.
echo "==> Setting GPU performance profile to ${PROFILE} (${PNAME})..."

insmod_output=$(LC_ALL=C insmod "${MODULE_KO}" profile="${PROFILE}" 2>&1)
INSMOD_RET=$?

# Success conditions:
# - Exit code 0: module loaded normally (shouldn't happen for our one-shot, but handle it)
# - Exit code 1 with EAGAIN/EEXIST: expected for one-shot or if already loaded once
if [[ $INSMOD_RET -eq 0 ]]; then
    : # Module loaded (unexpected for one-shot but not an error)
elif [[ $INSMOD_RET -eq 1 ]]; then
    # Check if this is an expected benign failure (EAGAIN = one-shot success)
    if echo "${insmod_output}" | grep -qiE "Resource temporarily unavailable|EAGAIN"; then
        : # Successful one-shot execution (module loaded, executed, auto-unloaded)
    elif echo "${insmod_output}" | grep -qiE "File exists|EEXIST"; then
        # Module already loaded from a previous run that didn't auto-unload;
        # this can happen if something went wrong. Not fatal — the DSM was already applied.
        echo "==> Module already loaded (from previous run)." >&2
    else
        echo "${insmod_output}" >&2
        die "insmod failed with exit code $INSMOD_RET. Check dmesg."
    fi
else
    echo "${insmod_output}" >&2
    die "insmod failed with unexpected exit code $INSMOD_RET."
fi

# Suppress expected benign messages from output
echo "${insmod_output}" | grep -vE "Resource temporarily unavailable|EAGAIN|File exists|EEXIST" || true

log_msg "gpu-perf: profile ${PROFILE} (${PNAME}) applied via _DSM"

# --- Force Enforce ---
# The DSM call is the PRIMARY trigger: it updates the EC's internal thermal/fan 
# profiles and modifies the ACPI OpRegion. However, the NVIDIA driver may 
# asynchronously reset power limits during this transition. We issue an explicit 
# '-pl' as a FALLBACK enforcement to ensure the target is locked in.
# NOTE: On driver >= R550, nvidia-smi -pl is blocked for platform-controlled GPUs.
#       This is expected — the _DSM call is the only working path. The -pl fallback
#       is best-effort only; failure does NOT indicate the profile wasn't applied.
if command -v nvidia-smi &>/dev/null && [[ "${PROFILE}" -ge 2 ]]; then
    sleep 0.5
    if ! nvidia-smi -pl "${TARGET_W}" &>/dev/null; then
        echo "==> Note: nvidia-smi -pl ${TARGET_W}W was blocked (expected on driver >= R550)." >&2
        echo "   The _DSM profile is the primary mechanism — the GPU is already unlocked." >&2
        log_msg "gpu-perf: nvidia-smi -pl ${TARGET_W}W not supported (platform-controlled GPU)"
    else
        log_msg "gpu-perf: nvidia-smi -pl ${TARGET_W}W enforced"
    fi
fi

# --- Validation ---
if command -v nvidia-smi &>/dev/null; then
    CURRENT_W=$(get_power_limit)
    # Give it a moment to apply (EC updates can be slow)
    sleep 2
    NEW_W=$(get_power_limit)
    
    echo "==> Power limit: ${CURRENT_W}W -> ${NEW_W}W"
    
    if [[ "${PROFILE}" -ge 2 ]]; then
        # For 100W profiles, we accept >= 80W as a success (P8 idle state)
        if [[ "${NEW_W}" -ge 80 ]]; then
            echo "✅ GPU unlocked (available up to 100W under load)"
        else
            echo "⚠️  GPU limit remains at ${NEW_W}W. A reboot might be required."
        fi
    else
        # For stock profiles, we expect exactly the target (70W)
        if [[ "${NEW_W}" -eq "${TARGET_W}" ]]; then
            echo "✅ Profile ${PNAME} applied (stock ${TARGET_W}W limit)."
        else
            echo "⚠️  GPU limit is ${NEW_W}W, expected ${TARGET_W}W."
        fi
    fi
    log_msg "gpu-perf: power limit ${CURRENT_W}W -> ${NEW_W}W (profile ${PROFILE})"
else
    echo "==> nvidia-smi not found, cannot verify power limit."
    log_msg "gpu-perf: profile ${PROFILE} set; nvidia-smi not available to verify"
fi

echo "Note: Power limits reset on reboot."
exit 0

