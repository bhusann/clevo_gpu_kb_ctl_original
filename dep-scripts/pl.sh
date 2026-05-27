#!/usr/bin/env bash

set -euo pipefail

PL1_UW=40000000
PL2_UW=80000000
STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/pl-normal-state"

RAPL_PATHS=(
  /sys/class/powercap/intel-rapl:0
  /sys/class/powercap/intel-rapl-mmio:0
)

backup_current_limits() {
  local tmp_state=$(mktemp)
  local zone
  for zone in "${RAPL_PATHS[@]}"; do
    [[ -d "$zone" ]] || continue
    local i name_file limit_file name value
    for i in 0 1 2; do
      name_file="$zone/constraint_${i}_name"
      limit_file="$zone/constraint_${i}_power_limit_uw"
      [[ -f "$name_file" && -f "$limit_file" ]] || continue

      name="$(cat "$name_file")"
      value="$(cat "$limit_file")"
      printf '%s|%s|%s\n' "$zone" "$name" "$value" >> "$tmp_state"
    done
  done
  mv "$tmp_state" "$STATE_FILE"
}

read_limit_by_name() {
  local zone="$1"
  local target_name="$2"
  local i name_file limit_file

  for i in 0 1 2; do
    name_file="$zone/constraint_${i}_name"
    limit_file="$zone/constraint_${i}_power_limit_uw"
    [[ -f "$name_file" && -f "$limit_file" ]] || continue
    if [[ "$(cat "$name_file")" == "$target_name" ]]; then
      cat "$limit_file"
      return 0
    fi
  done

  return 1
}

apply_limits() {
  # Build a single bash script to run as root
  local cmd="RAPL_PATHS=("
  for p in "${RAPL_PATHS[@]}"; do cmd+=" '$p'"; done
  cmd+="); "
  
  cmd+="for zone in \"\${RAPL_PATHS[@]}\"; do
    [[ -d \"\$zone\" ]] || continue
    for i in 0 1 2; do
      name_file=\"\$zone/constraint_\${i}_name\"
      limit_file=\"\$zone/constraint_\${i}_power_limit_uw\"
      [[ -f \"\$name_file\" && -f \"\$limit_file\" ]] || continue
      name=\$(cat \"\$name_file\")
      if [[ \"\$name\" == \"long_term\" ]]; then
        echo '$PL1_UW' > \"\$limit_file\"
      elif [[ \"\$name\" == \"short_term\" ]]; then
        echo '$PL2_UW' > \"\$limit_file\"
      fi
    done
  done"

  if sudo bash -c "$cmd"; then
    # Save state only AFTER successful apply — never clobber on cancellation
    backup_current_limits

    local zone="${RAPL_PATHS[0]}"
    local actual_pl1 actual_pl2
    actual_pl1="$(read_limit_by_name "$zone" long_term || true)"
    actual_pl2="$(read_limit_by_name "$zone" short_term || true)"

    if [[ "$actual_pl1" != "$PL1_UW" || "$actual_pl2" != "$PL2_UW" ]]; then
      notify-send -u critical "Power Limits" "Limits write did not fully stick. Current PL1=${actual_pl1:-unknown}, PL2=${actual_pl2:-unknown}"
      exit 1
    fi

    notify-send "Power Limits" "Custom limits applied: PL1=${PL1_UW%000000}W, PL2=${PL2_UW%000000}W"
  else
    notify-send -u critical "Power Limits" "Failed to apply limits (Auth cancelled?)"
    exit 1
  fi
}

restore_limits() {
  if [[ ! -f "$STATE_FILE" ]]; then
    notify-send -u critical "Power Limits" "No saved state found to restore."
    exit 1
  fi

  # Build a single bash script from the state file
  local cmd=""
  while IFS='|' read -r zone name value; do
    cmd+="for i in 0 1 2; do
      nf=\"$zone/constraint_\${i}_name\"
      lf=\"$zone/constraint_\${i}_power_limit_uw\"
      if [[ -f \"\$nf\" && \"\$(cat \"\$nf\")\" == \"$name\" ]]; then
        echo '$value' > \"\$lf\"
        break
      fi
    done; "
  done < "$STATE_FILE"

  if sudo bash -c "$cmd"; then
    rm -f "$STATE_FILE"
    notify-send "Power Limits" "Original system limits restored."
  else
    notify-send -u critical "Power Limits" "Failed to restore limits."
    exit 1
  fi
}

show_status() {
  local zone
  local status_msg=""
  for zone in "${RAPL_PATHS[@]}"; do
    [[ -d "$zone" ]] || continue
    status_msg="${status_msg}--- ${zone##*/}\n"
    for i in 0 1 2; do
      local name_file="$zone/constraint_${i}_name"
      local limit_file="$zone/constraint_${i}_power_limit_uw"
      [[ -f "$name_file" && -f "$limit_file" ]] || continue
      local name limit_value
      name="$(cat "$name_file")"
      limit_value="$(awk '{printf "%.1f", $1/1000000}' "$limit_file")"
      status_msg="${status_msg}${name}: ${limit_value} W\n"
    done
  done
  echo -e "$status_msg"
}

case "${1:-apply}" in
  apply|on|activate)
    apply_limits
    show_status
    ;;
  restore|normal|off|deactivate)
    restore_limits
    show_status
    ;;
  status)
    show_status
    ;;
  *)
    echo "Usage: $0 [apply|restore|status]"
    exit 1
    ;;
esac
