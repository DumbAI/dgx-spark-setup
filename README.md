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

For example, add `modules/30-dev-packages.sh`:

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

## Test the runner

```bash
python3 -B -m unittest discover -s tests -v
```

Tests use temporary modules and dry runs; they do not change host settings.
