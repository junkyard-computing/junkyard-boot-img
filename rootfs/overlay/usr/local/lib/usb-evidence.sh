# Shared helpers for the felix USB evidence recorders. Sourced, not executed.
# ud_dir NAME  -> prints a directory on userdata (mounted if needed), falling
#                 back to /run (tmpfs) so a record is at least readable this boot.
ud_dir() {
  local dev base
  dev=$(readlink -f /dev/disk/by-partlabel/userdata 2>/dev/null)
  base=""
  if [ -b "$dev" ]; then
    base=$(awk -v d="$dev" '$1==d{print $2; exit}' /proc/mounts)
    if [ -z "$base" ]; then
      mkdir -p /run/usb-evidence && mount -t ext4 -o noatime "$dev" /run/usb-evidence 2>/dev/null && base=/run/usb-evidence
    fi
  fi
  [ -n "$base" ] || base=/run/usb-evidence-fallback
  mkdir -p "$base/$1" && echo "$base/$1"
}
# snapshot_state -> Type-C roles, USB devices, NICs, power, healer journals
snapshot_state() {
  local P n d s
  P=/sys/class/typec/port0
  echo "when: $(date -Is) uptime: $(cut -d' ' -f1 /proc/uptime) boot_id: $(cat /proc/sys/kernel/random/boot_id)"
  echo "kernel: $(uname -rv)"
  echo "typec: power_role=$(cat $P/power_role 2>/dev/null) data_role=$(cat $P/data_role 2>/dev/null) partner=$([ -e $P/port0-partner ] && echo yes || echo no) pd=$(cat $P/port0-partner/supports_usb_power_delivery 2>/dev/null)"
  echo; echo "=== nics"; ip -br link 2>/dev/null; ip -4 -br addr 2>/dev/null
  for n in /sys/class/net/*; do echo "$(basename $n) carrier=$(cat $n/carrier 2>/dev/null) operstate=$(cat $n/operstate 2>/dev/null)"; done
  echo; echo "=== usb devices"
  for d in /sys/bus/usb/devices/*; do [ -f $d/idVendor ] && echo "$(basename $d) $(cat $d/idVendor):$(cat $d/idProduct) speed=$(cat $d/speed 2>/dev/null) $(cat $d/product 2>/dev/null)"; done
  echo; echo "=== power_supply"
  for s in /sys/class/power_supply/*; do echo "$(basename $s): online=$(cat $s/online 2>/dev/null) status=$(cat $s/status 2>/dev/null) V=$(cat $s/voltage_now 2>/dev/null) I=$(cat $s/current_now 2>/dev/null)"; done
  echo; echo "=== healers"
  journalctl -b --no-pager -o short-monotonic -u typec-host-fix -u typec-role-heal -u dongle-rehost -u usb-host-recover 2>/dev/null | tail -60
  echo; echo "=== debugfs tcpm ring"
  mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null
  cat /sys/kernel/debug/usb/tcpm-*/log 2>/dev/null
}
