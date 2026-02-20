#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# IO Scheduler interactive helper
# Author: github.com/galpt
# Purpose: detect block devices, show available I/O schedulers per-disk,
# let user apply them immediately and persist them across reboots via udev rules.

PROG_NAME=$(basename "$0")

_green() { printf "\033[1;32m%s\033[0m\n" "$*"; }
_yellow() { printf "\033[1;33m%s\033[0m\n" "$*"; }
_red() { printf "\033[1;31m%s\033[0m\n" "$*"; }

print_header() {
  cat <<'HEADER'

┌────────────────────────────────────────────────────────┐
│                IO Scheduler Setup — interactive         │
│                    Author: github.com/galpt            │
└────────────────────────────────────────────────────────┘

This script helps you examine block devices and their available I/O schedulers,
apply a scheduler immediately, and optionally make the selection persistent
across reboots by writing udev rules.

HEADER
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "$( _red "ERROR" ): required command '$1' not found."; exit 1; } }

ensure_prereqs() {
  require_cmd lsblk
  require_cmd awk
  require_cmd udevadm
}

check_root_or_sudo() {
  if [ "$EUID" -ne 0 ]; then
    echo
    echo "This script needs root — trying to re-run with sudo..."
    exec sudo bash "$0" "$@"
  fi
}

show_usage() {
  cat <<USAGE
Usage: $PROG_NAME [--remove <dev>] [--help]

Options:
  --remove <dev>   Remove any udev rule created by this script for <dev>
  --help           Show this help

Run interactively to enumerate disks and set schedulers.
USAGE
  exit 0
}

list_disks() {
  # Produce an array of lines: name|rota|model|size
  mapfile -t DISKS < <(lsblk -d -n -o NAME,ROTA,MODEL,SIZE,TYPE | awk '$5=="disk" {gsub(/^[ \t]+|[ \t]+$/,"",$3); print $1"|"$2"|"$3"|"$4}')
}

show_disk_menu() {
  echo
  echo "Detected block devices:"
  printf "%3s %-8s %-6s %-20s %s\n" "#" "name" "rota" "model" "size"
  echo "---------------------------------------------------------------"
  i=1
  for e in "${DISKS[@]}"; do
    IFS='|' read -r name rota model size <<< "$e"
    printf "%3s %-8s %-6s %-20s %s\n" "$i" "$name" "$rota" "$model" "$size"
    ((i++))
  done
  echo
}

prompt_select_disk() {
  while true; do
    read -rp "Select disk number to inspect (or 'q' to quit): " sel
    [[ "$sel" =~ ^[Qq]$ ]] && echo "Aborted." && exit 0
    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#DISKS[@]}" ]; then
      idx=$((sel-1))
      IFS='|' read -r SELECTED_NAME SELECTED_ROTA SELECTED_MODEL SELECTED_SIZE <<< "${DISKS[$idx]}"
      echo
      echo "Selected: $SELECTED_NAME — $SELECTED_MODEL ($SELECTED_SIZE)"
      break
    fi
    echo "Invalid selection — try again."
  done
}

get_available_schedulers() {
  local dev=$1
  local path="/sys/block/$dev/queue/scheduler"
  if [ ! -r "$path" ]; then
    echo ""
    return 1
  fi
  sched_raw=$(cat "$path" 2>/dev/null || true)
  # sched_raw looks like: noop [mq-deadline] kyber or [none] mq-deadline
  # produce space-separated list and mark selected with brackets stripped
  echo "$sched_raw"
}

current_selected_scheduler() {
  local raw=$1
  if [[ "$raw" =~ \[([^]]+)\] ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    # if none in brackets, pick first token
    echo "$raw" | awk '{print $1}'
  fi
}

apply_scheduler_now() {
  local dev=$1
  local sched=$2
  local path="/sys/block/$dev/queue/scheduler"
  if [ ! -w "$path" ]; then
    _red "Cannot write to $path — ensure kernel supports changing scheduler and run as root."
    return 1
  fi
  echo "$sched" > "$path"
  _green "Applied scheduler '$sched' to /sys/block/$dev/queue/scheduler"
}

udev_rule_path() { echo "/etc/udev/rules.d/60-io-scheduler.rules"; }

make_udev_rule_for() {
  local dev=$1
  local sched=$2
  local rulefile
  rulefile=$(udev_rule_path)
  # Backup existing rules if any
  if [ -f "$rulefile" ]; then
    cp -a "$rulefile" "$rulefile.bak.$(date +%s)" || true
  fi
  # Append a rule specific to this kernel device name
  # Use SUBSYSTEM=="block" so it matches block devices
  echo "# io-scheduler rule for $dev (created by $PROG_NAME)" >> "$rulefile"
  echo "SUBSYSTEM==\"block\", KERNEL==\"$dev\", ATTR{queue/scheduler}==\"$sched\", OPTIONS+=\"last_rule\"" >> "$rulefile"
  _green "Wrote rule to $rulefile"
  # reload rules and trigger
  udevadm control --reload-rules && udevadm trigger --action=change /sys/block/$dev || true
  _green "Reloaded udev rules and triggered change for $dev"
}

remove_udev_rule_for() {
  local dev=$1
  local rulefile
  rulefile=$(udev_rule_path)
  if [ ! -f "$rulefile" ]; then
    _yellow "No rulefile at $rulefile — nothing to remove."
    return 0
  fi
  # remove lines mentioning this dev and created by this script
  grep -v "created by $PROG_NAME" "$rulefile" | grep -v "KERNEL==\"$dev\"" > "$rulefile.tmp" || true
  mv "$rulefile.tmp" "$rulefile"
  _green "Removed rules for $dev from $rulefile"
  udevadm control --reload-rules && udevadm trigger --action=change /sys/block/$dev || true
}

show_current_state() {
  local dev=$1
  local sched_raw
  sched_raw=$(get_available_schedulers "$dev") || true
  if [ -z "$sched_raw" ]; then
    _yellow "No scheduler info available for /sys/block/$dev — skipping."
    return 1
  fi
  _green "Available schedulers for $dev:"
  echo "  $sched_raw"
  cur=$(current_selected_scheduler "$sched_raw") || true
  _yellow "Currently selected: $cur"
}

main_interactive() {
  check_root_or_sudo
  ensure_prereqs
  print_header
  list_disks
  if [ "${#DISKS[@]}" -eq 0 ]; then
    _red "No block disks found. Exiting."; exit 1
  fi
  show_disk_menu
  prompt_select_disk

  # Show scheduler info
  show_current_state "$SELECTED_NAME"
  sched_raw=$(get_available_schedulers "$SELECTED_NAME") || true
  if [ -z "$sched_raw" ]; then
    _red "This device does not expose scheduler choices. Exiting."; exit 1
  fi

  # Parse tokens into array keeping bracketed selection visible
  mapfile -t SCHED_TOKS < <(echo "$sched_raw" | sed -E 's/\[([^]]+)\]/\1/g' | tr ' ' '\n')

  echo
  echo "Choose scheduler to apply now (or 's' to skip):"
  i=1
  for s in "${SCHED_TOKS[@]}"; do
    printf "%3s %s\n" "$i" "$s"
    ((i++))
  done
  while true; do
    read -rp "Enter number (or 's' to skip): " choice
    if [[ "$choice" =~ ^[Ss]$ ]]; then
      _yellow "Skipping immediate apply."; break
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#SCHED_TOKS[@]}" ]; then
      sel_idx=$((choice-1))
      sel_sched=${SCHED_TOKS[$sel_idx]}
      apply_scheduler_now "$SELECTED_NAME" "$sel_sched"
      break
    fi
    echo "Invalid selection — try again."
  done

  echo
  if ask_yes_no "Create persistent udev rule to set scheduler for $SELECTED_NAME on boot?"; then
    # pick scheduler to persist (default to currently selected if any)
    cur=$(current_selected_scheduler "$sched_raw")
    read -rp "Enter scheduler to persist [${cur}]: " persist_in
    persist_in=${persist_in:-$cur}
    # Validate
    ok=0
    for s in "${SCHED_TOKS[@]}"; do
      if [ "$s" = "$persist_in" ]; then ok=1; break; fi
    done
    if [ "$ok" -ne 1 ]; then
      _red "Invalid scheduler '$persist_in' — aborting persistent rule creation."; exit 1
    fi
    make_udev_rule_for "$SELECTED_NAME" "$persist_in"
  else
    _yellow "No persistent rule created."
  fi

  echo
  _green "Done. To remove a previously created rule for a device, re-run with --remove <dev>."
}

ask_yes_no() {
  local prompt="$1" default_answer="Y"
  read -rp "$prompt [Y/n]: " answer
  answer=${answer:-$default_answer}
  [[ "$answer" =~ ^([yY][eE][sS]|[yY])$ ]]
}

# Quick non-interactive remove
if [ "${1-}" = "--remove" ]; then
  check_root_or_sudo
  if [ -z "${2-}" ]; then echo "Usage: $PROG_NAME --remove <dev>"; exit 1; fi
  remove_udev_rule_for "$2"; exit 0
fi

if [ "${1-}" = "--help" ] || [ "${1-}" = "-h" ]; then show_usage; fi

main_interactive "$@"
