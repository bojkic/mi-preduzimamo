"""Real Git/filesystem crash recovery with Docker command doubles."""
import argparse
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "script/lib"))
from mi_installer import Installation, InstallError
from mi_upgrade import Upgrade
from mi_recovery import atomic_private
from test_recovery import RecoveryInstallation, RecoveryDouble


class GitInstallation(RecoveryInstallation):
    source = Installation.source
    context = Installation.context

    def run(self, name, args, capture=False):
        if args[0] == "git":
            self.calls.append((name, args))
            result = subprocess.run(args, capture_output=True, text=True, env=self.environment)
            if result.returncode:
                raise InstallError("Synthetic Git operation rejected")
            if name == "upgrade-checkout" and self.fail == "checkout-after-git":
                raise InstallError("Synthetic interruption after checkout")
            return result.stdout.strip()
        result = super().run(name, args, capture)
        if name == "upgrade-image-identity":
            return "sha256:" + "9" * 64
        if name == "runtime-image":
            return self.config["image_id"]
        return result


class UpgradeSafetyTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.environment = patch.dict(os.environ, {"PATH": "/usr/bin:/bin", "HOME": str(self.root)}, clear=True)
        self.environment.start()
        self.disk = patch("mi_installer.shutil.disk_usage", return_value=type("Disk", (), {"free": 30 * 1024**3})())
        self.disk.start()
        self.port = patch("mi_installer.Installation.port_available")
        self.port.start()
        self.recovery = patch("mi_upgrade.Recovery", RecoveryDouble)
        self.recovery.start()
        self.git("init", "-q")
        self.git("config", "user.name", "Synthetic upgrade test")
        self.git("config", "user.email", "test@example.invalid")
        (self.root / ".gitignore").write_text(".mi-install/\n.mi-install.lock\n__pycache__/\n")
        module = self.root / "script/lib/mi_upgrade.py"
        module.parent.mkdir(parents=True)
        shutil.copy2(Path(__file__).resolve().parents[2] / "script/lib/mi_upgrade.py", module)
        shutil.copy2(Path(__file__).resolve().parents[2] / "compose.yml", self.root / "compose.yml")
        self.write_lock("b" * 40)
        self.git("add", ".")
        self.git("commit", "-qm", "Synthetic old source")
        self.old_sha = self.git("rev-parse", "HEAD")
        self.write_lock("c" * 40)
        (self.root / "CHANGELOG.md").write_text("Synthetic upgrade candidate\n")
        self.git("add", ".")
        self.git("commit", "-qm", "Synthetic new source")
        self.target = self.git("rev-parse", "HEAD")
        self.git("checkout", "--detach", self.old_sha)
        self.i = GitInstallation(self.root)
        args = argparse.Namespace(profile="demo", domain=None, web_port=3100, mail_port=8125, docker_host=None, capture_phone=False)
        with contextlib.redirect_stdout(io.StringIO()):
            self.i.prepare(args)
            self.i.resume()
        self.original = (self.i.state / "app.env").read_bytes()
        self.i.calls.clear()
        self.upgrade = Upgrade(self.i)

    def tearDown(self):
        self.recovery.stop()
        self.port.stop()
        self.disk.stop()
        self.environment.stop()
        self.temp.cleanup()

    def git(self, *args):
        result = subprocess.run(["git", "-C", str(self.root), *args], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError("Synthetic Git fixture setup failed")
        return result.stdout.strip()

    def write_lock(self, engine):
        (self.root / "Gemfile.lock").write_text("GIT\n  remote: https://example.invalid/engine.git\n  revision: " + engine + "\n  specs:\n    decidim-bih (0.4.0)\n\n")

    def start(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.upgrade.start(self.target)

    def test_success_builds_before_quiesce_and_backs_up_before_checkout_and_migrations(self):
        self.start()
        names = [name for name, _ in self.i.calls]
        self.assertLess(names.index("upgrade-image-build"), names.index("backup-worker-quiet"))
        self.assertLess(names.index("backup-app-image.tar"), names.index("upgrade-checkout"))
        self.assertLess(names.index("upgrade-checkout"), names.index("upgrade-migrations"))
        self.assertLess(names.index("upgrade-migrations"), names.index("services-start"))
        self.assertEqual(self.target, self.git("rev-parse", "HEAD"))
        self.assertEqual(self.target, self.i.config["source"]["app_sha"])
        self.assertEqual("c" * 40, self.i.config["source"]["engine_sha"])
        self.assertEqual(self.original, (self.i.state / "app.env").read_bytes())
        self.assertNotIn("upgrade", self.i.config)
        backup = Path(self.i.config["last_upgrade"]["backup"]["path"])
        saved = json.loads((backup / "manifest.json").read_text())["configuration"]
        self.assertNotIn("upgrade", saved)
        self.assertEqual(self.old_sha, saved["source"]["app_sha"])
        self.assertEqual("Synthetic upgrade candidate\n", (self.i.state / "build-context/CHANGELOG.md").read_text())
        self.i.load()

    def test_build_failure_preserves_running_old_pair_and_can_abort(self):
        self.i.fail = "upgrade-image-build"
        with self.assertRaises(InstallError):
            self.start()
        self.assertEqual("building", self.i.config["upgrade"]["phase"])
        self.assertEqual(self.old_sha, self.git("rev-parse", "HEAD"))
        self.assertNotIn("backup-worker-quiet", [name for name, _ in self.i.calls])
        self.i.fail = None
        with contextlib.redirect_stdout(io.StringIO()):
            self.upgrade.abort()
        self.assertNotIn("upgrade", self.i.config)
        self.assertEqual(self.original, (self.i.state / "app.env").read_bytes())

    def test_migration_failure_stays_on_new_pair_and_resumes_without_rebuild_or_new_keys(self):
        self.i.fail = "upgrade-migrations"
        with self.assertRaises(InstallError):
            self.start()
        self.assertEqual("migrating", self.i.config["upgrade"]["phase"])
        self.assertEqual(self.target, self.git("rev-parse", "HEAD"))
        with self.assertRaises(InstallError):
            self.upgrade.abort()
        self.i.fail = None
        self.i.calls.clear()
        self.i.load()
        with contextlib.redirect_stdout(io.StringIO()):
            self.upgrade.resume()
        self.assertNotIn("upgrade-image-build", [name for name, _ in self.i.calls])
        self.assertNotIn("backup-app-image.tar", [name for name, _ in self.i.calls])
        self.assertEqual(self.original, (self.i.state / "app.env").read_bytes())

    def test_interruption_after_git_checkout_is_reconciled_by_fresh_load(self):
        self.i.fail = "checkout-after-git"
        with self.assertRaises(InstallError):
            self.start()
        self.assertEqual("cutover", self.i.config["upgrade"]["phase"])
        self.assertEqual(self.target, self.git("rev-parse", "HEAD"))
        self.assertEqual(self.old_sha, self.i.config["source"]["app_sha"])
        fresh = GitInstallation(self.root)
        fresh.load()
        self.assertEqual("migrating", fresh.config["upgrade"]["phase"])
        self.assertEqual(self.target, fresh.config["source"]["app_sha"])
        with contextlib.redirect_stdout(io.StringIO()):
            Upgrade(fresh).resume()
        self.assertNotIn("upgrade", fresh.config)
        self.assertEqual(self.original, (fresh.state / "app.env").read_bytes())

    def test_interruption_after_compose_replace_is_reconciled_without_replacing_secrets(self):
        def interrupt(path, value):
            atomic_private(path, value)
            raise OSError("Synthetic interrupted config completion")
        with patch("mi_upgrade.atomic_private", side_effect=interrupt):
            with self.assertRaises(OSError):
                self.start()
        fresh = GitInstallation(self.root)
        fresh.load()
        self.assertEqual("migrating", fresh.config["upgrade"]["phase"])
        self.assertIn("MI_APP_SHA=" + self.target, (fresh.state / "compose.env").read_text())
        self.assertEqual(self.original, (fresh.state / "app.env").read_bytes())

    def test_failed_backup_can_abort_before_migration_without_deleting_partial_copy(self):
        self.i.fail = "backup-volumes.tar"
        with self.assertRaises(InstallError):
            self.start()
        directory = Path(self.i.config["maintenance"]["path"])
        self.assertTrue((directory / "database.dump").exists())
        self.i.fail = None
        with contextlib.redirect_stdout(io.StringIO()):
            self.upgrade.abort()
        self.assertEqual(self.old_sha, self.git("rev-parse", "HEAD"))
        self.assertTrue((directory / "database.dump").exists())
        self.assertEqual(str(directory), self.i.config["abandoned_snapshots"][-1]["path"])

    def test_repeated_current_revision_and_missing_commit_are_rejected_before_upgrade_intent(self):
        for revision in (self.old_sha, "0" * 40):
            with self.subTest(revision=revision), self.assertRaises(InstallError):
                self.upgrade.start(revision)
            self.assertNotIn("upgrade", self.i.config)
        self.assertEqual(self.old_sha, self.git("rev-parse", "HEAD"))

    def test_database_major_and_storage_mapping_changes_are_rejected_before_build(self):
        for old, new in (("postgres:18.6-bookworm", "postgres:19.1-bookworm"), ("storage:/app/storage", "storage_new:/app/storage")):
            self.git("checkout", "--detach", self.target)
            path = self.root / "compose.yml"
            path.write_text(path.read_text().replace(old, new))
            self.git("add", ".")
            self.git("commit", "-qm", "Synthetic unsupported data layout")
            wrong = self.git("rev-parse", "HEAD")
            self.git("checkout", "--detach", self.old_sha)
            with self.subTest(change=new), self.assertRaises(InstallError):
                self.upgrade.start(wrong)
            self.assertNotIn("upgrade", self.i.config)
        self.assertNotIn("upgrade-image-build", [name for name, _ in self.i.calls])

    def test_wrong_protocol_is_rejected_before_stopping_old_services(self):
        self.git("checkout", "--detach", self.target)
        module = self.root / "script/lib/mi_upgrade.py"
        module.write_text(module.read_text().replace("    FORMAT = 1\n", "    FORMAT = 2\n"))
        self.git("add", ".")
        self.git("commit", "-qm", "Synthetic incompatible protocol")
        wrong = self.git("rev-parse", "HEAD")
        self.git("checkout", "--detach", self.old_sha)
        with self.assertRaises(InstallError):
            self.upgrade.start(wrong)
        self.assertNotIn("upgrade", self.i.config)
        self.assertNotIn("backup-worker-quiet", [name for name, _ in self.i.calls])


if __name__ == "__main__":
    unittest.main()
