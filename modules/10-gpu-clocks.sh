#!/usr/bin/env bash

module_description() {
    printf 'Limit GPU clocks to 2200 MHz now and at boot.\n'
}

module_check() {
    require_commands nvidia-smi systemctl install
    require_systemd
    nvidia-smi -L
}

module_apply() {
    local nvidia_smi
    nvidia_smi=$(command -v nvidia-smi)

    # nvidia-smi clock locks must be reapplied after a reboot.
    cat > "$SETUP_WORK_DIR/clocks.service" <<EOF
[Unit]
Description=DGX Spark GPU clock limit (2200 MHz)
After=systemd-modules-load.service nvidia-persistenced.service

[Service]
Type=oneshot
ExecStart=$nvidia_smi -lgc 0,2200
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    install_config "$SETUP_WORK_DIR/clocks.service" /etc/systemd/system/dgx-spark-gpu-clocks.service
    run systemctl daemon-reload
    run systemctl enable dgx-spark-gpu-clocks.service
    # Restart also reapplies the limit when this module is run again.
    run systemctl restart dgx-spark-gpu-clocks.service

    if ! "$SETUP_DRY_RUN"; then
        printf 'GPU clock range set to 0–2200 MHz and enabled at boot.\n'
    fi
}
