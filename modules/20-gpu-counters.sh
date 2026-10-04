#!/usr/bin/env bash

module_description() {
    printf 'Allow all users to access GPU performance counters.\n'
}

module_check() {
    require_commands nvidia-smi modinfo update-initramfs install
    nvidia-smi -L
    if ! modinfo -p nvidia | grep '^NVreg_RestrictProfilingToAdminUsers:' >/dev/null; then
        die 'The installed NVIDIA driver does not expose NVreg_RestrictProfilingToAdminUsers.'
    fi
}

module_apply() {
    # NVIDIA's documented setting for unrestricted performance counter access.
    cat > "$SETUP_WORK_DIR/counters.conf" <<'EOF'
# Managed by dgx-spark-setup/modules/20-gpu-counters.sh.
options nvidia NVreg_RestrictProfilingToAdminUsers=0
EOF

    install_config "$SETUP_WORK_DIR/counters.conf" /etc/modprobe.d/dgx-spark-dev-counters.conf
    # Always rebuild so a previously failed rebuild is retried on reruns.
    run update-initramfs -u -k all

    if ! "$SETUP_DRY_RUN"; then
        if grep '^RmProfilingAdminOnly: *0$' /proc/driver/nvidia/params >/dev/null 2>&1; then
            printf 'GPU performance counters are available to all users.\n'
        else
            printf 'Counter access configured. Reboot to activate it: sudo reboot\n'
        fi
    fi
}
