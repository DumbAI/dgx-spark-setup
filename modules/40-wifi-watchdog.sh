#!/usr/bin/env bash

module_description() {
    printf 'Probe the Wi-Fi gateway every minute and repair a wedged link.\n'
}

# Kernel module behind a network device, e.g. mt7925e.
wifi_driver() {
    local module
    module=$(readlink -f "/sys/class/net/$1/device/driver/module" 2>/dev/null) || return 0
    printf '%s\n' "${module##*/}"
}

module_check() {
    local device connection
    read -r device connection <<<"$(active_wifi)"
    if [[ -z "$device" ]]; then
        printf 'No active Wi-Fi connection; this module will be skipped.\n'
        return
    fi
    require_commands systemctl install ip ping logger modprobe
    require_systemd
    [[ -n "$(wifi_driver "$device")" ]] || die "Cannot determine the driver module for $device."
}

module_apply() {
    local device connection driver files_dir
    read -r device connection <<<"$(active_wifi)"
    if [[ -z "$device" ]]; then
        printf 'No active Wi-Fi connection; skipped.\n'
        return
    fi
    driver=$(wifi_driver "$device")
    files_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../files" && pwd)

    # Detected on every run, so a rerun picks up a renamed network or new adapter.
    cat > "$SETUP_WORK_DIR/wifi-watchdog.conf" <<EOF
# Managed by dgx-spark-setup/modules/40-wifi-watchdog.sh.
IFACE=$device
CONN=$connection
DRIVER=$driver
# Minimum seconds between watchdog-initiated reboots; prevents a reboot loop
# when the router itself is down and rebooting cannot help.
REBOOT_MIN_INTERVAL=21600
EOF

    cat > "$SETUP_WORK_DIR/wifi-watchdog.service" <<'EOF'
[Unit]
Description=Wi-Fi self-repair probe
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/wifi-watchdog
# A wedged driver can make modprobe/nmcli hang; never let one run block the timer.
TimeoutStartSec=120
EOF

    # A timer instead of a long-running loop: each probe starts fresh, and a new
    # one starts only after the previous one finishes, so repairs never overlap.
    cat > "$SETUP_WORK_DIR/wifi-watchdog.timer" <<'EOF'
[Unit]
Description=Run wifi-watchdog every minute

[Timer]
OnBootSec=3min
OnUnitInactiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF

    run install -D -o root -g root -m 0755 "$files_dir/wifi-watchdog" /usr/local/sbin/wifi-watchdog
    install_config "$SETUP_WORK_DIR/wifi-watchdog.conf" /etc/default/wifi-watchdog
    install_config "$SETUP_WORK_DIR/wifi-watchdog.service" /etc/systemd/system/wifi-watchdog.service
    install_config "$SETUP_WORK_DIR/wifi-watchdog.timer" /etc/systemd/system/wifi-watchdog.timer
    run systemctl daemon-reload
    run systemctl enable --now wifi-watchdog.timer

    if ! "$SETUP_DRY_RUN"; then
        printf 'wifi-watchdog enabled for %s (%s, driver %s).\n' "$connection" "$device" "$driver"
    fi
}
