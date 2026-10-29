# DGX Spark development setup

Configure an Ubuntu/DGX OS host with the NVIDIA driver already installed:

```bash
./setup-dev.sh --dry-run
sudo ./setup-dev.sh
```

List modules or run a subset:

```bash
./setup-dev.sh --list
./setup-dev.sh --dry-run gpu-clocks
sudo ./setup-dev.sh gpu-counters
```

With no module names, the runner applies all modules. Selected modules always
run in filename order, regardless of argument order. All selected preflight
checks must pass before application starts; any failure stops the runner.
Already applied changes are not automatically rolled back on failure.

The included modules:

- `gpu-clocks` applies `nvidia-smi -lgc 0,2200` immediately to limit the GPU clock to
  2200 MHz and help reduce heat. It installs a systemd service to reapply the
  limit at boot.
- `gpu-counters` enables GPU performance counters for all users with
  `options nvidia NVreg_RestrictProfilingToAdminUsers=0`, then rebuilds the
  initramfs for all installed kernels.
- `wifi-powersave` disables power saving on the active Wi-Fi connection, both in
  its saved NetworkManager settings and on the live link (without reconnecting).
  Power saving raised ping latency from about 7 ms to over 100 ms and likely
  triggered the link drop described below.
- `wifi-watchdog` installs a systemd timer that pings the Wi-Fi gateway every
  minute and repairs the link after consecutive failures: reconnect (2nd
  failure), reload the Wi-Fi driver (4th), then reboot (8th, and every 4th after
  that), at most once every 6 hours. The interface, connection, and driver are
  detected at setup time and written to `/etc/default/wifi-watchdog`.

Both Wi-Fi modules skip themselves on hosts without an active Wi-Fi connection.
Wired Ethernet remains the most reliable option; the watchdog only shortens
outages.

Reboot when the script reports that counter access needs activation:

```bash
sudo reboot
```

The script leaves rebooting to you and does not unload the running driver.
Rerunning it updates the same configuration files and reapplies the clock limit.
It targets drivers exposing `NVreg_RestrictProfilingToAdminUsers`, including the
580 driver installed on this Spark. See
[NVIDIA's performance counter instructions](https://developer.nvidia.com/nvidia-development-tools-solutions-err_nvgpuctrperm-permission-issue-performance-counters)
for the driver option and initramfs procedure.

## Add a setup module

The runner discovers `modules/NN-name.sh` automatically. The two-digit prefix
controls execution order; `name` is the CLI module name. No runner changes or
registration are needed. Each module must work independently when selected alone.

For example, add `modules/50-dev-packages.sh`:

```bash
#!/usr/bin/env bash

module_description() {
    printf 'Install common development tools.\n'
}

module_check() {
    require_commands apt-get
}

module_apply() {
    run apt-get update
    run apt-get install -y build-essential git cmake ninja-build
}
```

It will appear in `./setup-dev.sh --list`, run as part of the default setup,
and be selectable with `sudo ./setup-dev.sh dev-packages`.

Module conventions:

- Define the three hooks shown above. Keep top-level code limited to declarations;
  modules are sourced even when listing or checking them.
- Keep `module_check` read-only and check only that module's prerequisites.
  Checks and application run in separate subshells, so variables set by a check
  are not available during application.
- Make `module_apply` safe to rerun. Route system changes through `run COMMAND ...`
  so `--dry-run` previews them. Avoid shell redirections to system files outside
  the command passed to `run`.
- Write configuration into `$SETUP_WORK_DIR`, then call
  `install_config SOURCE DESTINATION`. The runner creates and cleans up a private
  temporary directory for each module, including during dry runs.
- Shared helpers in `lib/common.sh` include `die`, `require_commands`,
  `require_systemd`, `run`, and `install_config`. `$SETUP_DRY_RUN` is `true` or
  `false`. All modules run as root during actual setup.

## Verify after reboot

```bash
# Expect RmProfilingAdminOnly: 0.
grep RmProfilingAdminOnly /proc/driver/nvidia/params

# Expect enabled and active (exited), with a successful nvidia-smi invocation.
systemctl is-enabled dgx-spark-gpu-clocks.service
systemctl status dgx-spark-gpu-clocks.service --no-pager
journalctl -b -u dgx-spark-gpu-clocks.service --no-pager

# Observe current temperature and graphics clock during your workload.
nvidia-smi --query-gpu=name,temperature.gpu,clocks.gr --format=csv

# Expect "Power save: off" and "disable" (use your interface and connection names).
iw dev wlP9s9 get power_save
nmcli -g 802-11-wireless.powersave connection show shamiumiu

# Expect the timer enabled with a next run within a minute. The log stays empty
# while the link is healthy.
systemctl list-timers wifi-watchdog.timer --no-pager
journalctl -t wifi-watchdog --no-pager
```

## Undo

```bash
sudo systemctl disable --now dgx-spark-gpu-clocks.service
sudo rm /etc/systemd/system/dgx-spark-gpu-clocks.service
sudo systemctl daemon-reload
sudo nvidia-smi -rgc
sudo rm /etc/modprobe.d/dgx-spark-dev-counters.conf
sudo update-initramfs -u -k all
sudo reboot
```

Removing the counter configuration restores the driver's default permissions
after reboot, unless another modprobe configuration overrides them.

Undo the Wi-Fi modules (no reboot needed):

```bash
sudo systemctl disable --now wifi-watchdog.timer
sudo rm /etc/systemd/system/wifi-watchdog.{service,timer} /usr/local/sbin/wifi-watchdog \
    /etc/default/wifi-watchdog
sudo rm -rf /var/lib/wifi-watchdog
sudo systemctl daemon-reload
sudo nmcli connection modify shamiumiu 802-11-wireless.powersave 0  # 0 = driver default
```

## Wi-Fi drop: what happened and how to diagnose

On 2026-10-21 the Spark's Wi-Fi (MediaTek `mt7925e`) dropped for inactivity,
NetworkManager's reconnect failed with `ssid-not-found`, and after a firmware
reset the driver never rejoined the network. The Spark stayed offline for a
week, until it was rebooted. From the network it looked like an SSH failure:
`spark-2970.local` stopped resolving over mDNS, and NVIDIA Sync emptied its
generated `ssh_config`.

If the Spark disappears again, check from another machine first:

```bash
dns-sd -G v4 spark-2970.local     # macOS mDNS lookup; no answer = host off the network
ping -c3 spark-2970.local
```

Then, on the Spark (console or after it is back):

```bash
last -x | head                                   # reboots and shutdowns
journalctl -b -1 -p warning --no-pager | tail -50 # errors from the previous boot
journalctl -u NetworkManager --since "2 days ago" --no-pager | grep -iE 'wlP9s9|state change|ssid'
journalctl -k --since "2 days ago" --no-pager | grep -i mt79   # driver/firmware resets
journalctl -t wifi-watchdog --no-pager           # repairs the watchdog attempted
```

## Test the runner

```bash
python3 -B -m unittest discover -s tests -v
```

Tests use temporary modules and dry runs; they do not change host settings.
