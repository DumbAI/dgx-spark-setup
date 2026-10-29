#!/usr/bin/env bash

module_description() {
    printf 'Disable Wi-Fi power saving, which adds latency and drops idle links.\n'
}

module_check() {
    if [[ -z "$(active_wifi)" ]]; then
        printf 'No active Wi-Fi connection; this module will be skipped.\n'
        return
    fi
    require_commands iw
}

module_apply() {
    local device connection
    read -r device connection <<<"$(active_wifi)"
    if [[ -z "$device" ]]; then
        printf 'No active Wi-Fi connection; skipped.\n'
        return
    fi

    # 2 = disable. Stored on the connection, so it survives reconnects and reboots.
    run nmcli connection modify "$connection" 802-11-wireless.powersave 2
    # Also apply to the live link: reactivating the connection would drop SSH sessions.
    run iw dev "$device" set power_save off

    if ! "$SETUP_DRY_RUN"; then
        printf 'Wi-Fi power saving disabled for %s on %s.\n' "$connection" "$device"
    fi
}
