"""Exercise the module runner in a temporary checkout without changing the host."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SetupRunnerTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="spark setup tests ")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        shutil.copy2(ROOT / "setup-dev.sh", self.root)
        shutil.copytree(ROOT / "lib", self.root / "lib")
        (self.root / "modules").mkdir()

    def module(self, filename, check="true", apply="true"):
        name = filename.split("-", 1)[1].removesuffix(".sh")
        path = self.root / "modules" / filename
        path.write_text(
            f"module_description() {{ printf 'Description of {name}\\n'; }}\n"
            f"module_check() {{\n printf 'check:{name}\\n'\n {check}\n}}\n"
            f"module_apply() {{\n printf 'apply:{name}\\n'\n {apply}\n}}\n"
        )
        return path

    def invoke(self, *args):
        # A different working directory also checks path resolution, including spaces.
        return subprocess.run(
            ["bash", str(self.root / "setup-dev.sh"), *args],
            cwd="/",
            text=True,
            capture_output=True,
            timeout=10,
        )

    def events(self, result):
        return [
            line for line in result.stdout.splitlines()
            if line.startswith(("check:", "apply:"))
        ]

    def test_new_modules_are_discovered_and_all_checks_run_first(self):
        self.module("20-second.sh")
        self.module("10-first.sh")
        self.module("30-extension.sh")
        result = self.invoke("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(result), [
            "check:first", "check:second", "check:extension",
            "apply:first", "apply:second", "apply:extension",
        ])

    def test_list_does_not_check_or_apply(self):
        self.module("10-first.sh", check="false", apply="false")
        result = self.invoke("--list")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Description of first", result.stdout)
        self.assertEqual(self.events(result), [])

    def test_selection_keeps_order_deduplicates_and_skips_other_checks(self):
        self.module("10-first.sh")
        self.module("20-unselected.sh", check="false")
        self.module("30-last.sh")
        result = self.invoke("--dry-run", "last", "first", "last")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(result), [
            "check:first", "check:last", "apply:first", "apply:last",
        ])

    def test_bad_selection_stops_before_any_check(self):
        self.module("10-first.sh")
        for args in [("--dry-run", "missing"), ("--bad-option",)]:
            with self.subTest(args=args):
                result = self.invoke(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Unknown", result.stderr)
                self.assertEqual(self.events(result), [])

    def test_failed_check_prevents_every_apply(self):
        self.module("10-first.sh")
        self.module("20-broken.sh", check="false\n printf 'unreachable\\n'")
        result = self.invoke("--dry-run")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.events(result), ["check:first", "check:broken"])
        self.assertNotIn("unreachable", result.stdout)

    def test_failed_apply_stops_later_modules_and_cleans_temporary_files(self):
        self.module("10-broken.sh", apply=(
            "printf 'workdir:%s\\n' \"$SETUP_WORK_DIR\"\n"
            "false\n printf 'unreachable\\n'"
        ))
        self.module("20-later.sh")
        result = self.invoke("--dry-run")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.events(result), ["check:broken", "check:later", "apply:broken"])
        self.assertNotIn("unreachable", result.stdout)
        work_dir = next(line.removeprefix("workdir:") for line in result.stdout.splitlines()
                        if line.startswith("workdir:"))
        self.assertFalse(Path(work_dir).exists())

    def test_dry_run_previews_commands_and_configs_without_installing(self):
        # Destinations would be harmless even if a regression executed these commands.
        self.module("10-preview.sh", apply=(
            'destination="$script_dir/installed.conf"\n'
            'run touch "$script_dir/changed"\n'
            'printf "example configuration\\n" > "$SETUP_WORK_DIR/example.conf"\n'
            'install_config "$SETUP_WORK_DIR/example.conf" "$destination"'
        ))
        result = self.invoke("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("+ touch", result.stdout)
        self.assertIn("example configuration", result.stdout)
        self.assertFalse((self.root / "changed").exists())
        self.assertFalse((self.root / "installed.conf").exists())

    def test_module_check_variables_do_not_leak(self):
        self.module("10-first.sh", check="check_value=secret", apply="[[ ! -v check_value ]]")
        self.module("20-second.sh", check="[[ ! -v check_value ]]")
        result = self.invoke("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_hook_cannot_inherit_previous_module_hook(self):
        self.module("10-first.sh")
        (self.root / "modules" / "20-incomplete.sh").write_text(
            "module_description() { echo incomplete; }\nmodule_check() { true; }\n"
        )
        result = self.invoke("--dry-run")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("incomplete is missing module_apply()", result.stderr)
        self.assertEqual(self.events(result), ["check:first"])

    def test_duplicate_module_names_are_rejected(self):
        self.module("10-first.sh")
        self.module("20-first.sh")
        result = self.invoke("--dry-run")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Duplicate module name: first", result.stderr)
        self.assertEqual(self.events(result), [])

    @unittest.skipIf(os.geteuid() == 0, "Root guard requires a non-root test process")
    def test_actual_setup_requires_root(self):
        self.module("10-first.sh")
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Run with sudo", result.stderr)
        self.assertEqual(self.events(result), [])


if __name__ == "__main__":
    unittest.main()
