"""Filesystem/process contract tests; these are NOT a Docker install acceptance."""
import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "script/lib"))
import mi_installer as installer


class DockerDouble(installer.Installation):
    def __init__(self, root):
        super().__init__(root)
        self.docker = "/usr/bin/docker"
        self.calls = []
        self.fail = None
        self.daemon_id = "daemon-a"
        self.worker_active = True
        self.volume_rows = ""

    def source(self):
        return {"app_sha": "a" * 40, "engine_sha": "b" * 40, "lock_sha256": "c" * 64}

    def run(self, name, args, capture=False):
        self.calls.append((name, args))
        if name == self.fail:
            raise installer.InstallError("Controlled failure")
        return {"selected-image": self.config.get("image_id", ""), "worker-running": "e" * 64 if self.worker_active else "", "compose-version": "2.30.0", "built-image": "sha256:" + "d" * 64, "runtime-image": "sha256:" + "d" * 64, "runtime-containers": "e" * 64 + "\n" + "f" * 64, "docker-identity": self.daemon_id, "docker-memory": str(8 * 1024**3), "resource-identity": self.volume_rows}.get(name, "")

    def context(self, **kwargs):
        self.calls.append(("context", []))


class InstallerSafetyTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.env = patch.dict(os.environ, {"PATH": os.environ["PATH"], "HOME": os.environ["HOME"]}, clear=True)
        self.env.start()
        self.disk = patch.object(installer.shutil, "disk_usage", return_value=shutil._ntuple_diskusage(30 * 1024**3, 0, 30 * 1024**3))
        self.disk.start()
        self.port = patch.object(installer.Installation, "port_available")
        self.port.start()
        self.subject = DockerDouble(self.root)
        self.args = argparse.Namespace(command="install", profile="demo", domain=None, web_port=3100, mail_port=8125, docker_host="unix:///var/run/docker.sock", capture_phone=False)

    def tearDown(self):
        self.port.stop()
        self.disk.stop()
        self.env.stop()
        self.temporary.cleanup()

    def prepare(self):
        self.subject.prepare(self.args)
        return self.subject

    def operation(self, command):
        return argparse.Namespace(command=command, profile=None, domain=None, web_port=None, mail_port=None, docker_host=None, capture_phone=False)

    def test_configuration_uses_independent_secrets_and_separate_bootstrap_credentials(self):
        s = self.prepare()
        app = dict(line.split("=", 1) for line in (s.state / "app.env").read_text().splitlines())
        db = dict(line.split("=", 1) for line in (s.state / "db.env").read_text().splitlines())
        self.assertEqual(4, len({app["SECRET_KEY_BASE"], app["DECIDIM_API_JWT_SECRET"], app["DATABASE_PASSWORD"], db["POSTGRES_PASSWORD"]}))
        self.assertNotIn("POSTGRES_PASSWORD", app)
        self.assertIn(app["DATABASE_PASSWORD"], app["DATABASE_URL"])
        self.assertEqual(app["DATABASE_PASSWORD"], db["MI_APP_DATABASE_PASSWORD"])
        for name in ["app.env", "db.env", "compose.env", "config.json"]:
            self.assertEqual(0o600, (s.state / name).stat().st_mode & 0o777)
        self.assertEqual(0o700, s.state.stat().st_mode & 0o777)

    def test_second_installation_generates_separate_keys_without_reading_first_state(self):
        first = self.prepare()
        before = {name: (first.state / name).read_bytes() for name in ("app.env", "db.env", "compose.env")}
        second_root = self.root / "second"
        second_root.mkdir()
        second = DockerDouble(second_root)
        args = argparse.Namespace(**vars(self.args))
        args.web_port, args.mail_port = 3200, 8225
        second.prepare(args)
        for name in ("app.env", "db.env"):
            left = dict(line.split("=", 1) for line in before[name].decode().splitlines())
            right = dict(line.split("=", 1) for line in (second.state / name).read_text().splitlines())
            keys = ("SECRET_KEY_BASE", "DECIDIM_API_JWT_SECRET", "DATABASE_PASSWORD") if name == "app.env" else ("POSTGRES_PASSWORD",)
            for key in keys:
                self.assertNotEqual(left[key], right[key])
        self.assertNotEqual(first.config["project"], second.config["project"])
        self.assertEqual(before, {name: (first.state / name).read_bytes() for name in before})

    def test_install_refuses_existing_configuration_without_changing_any_bytes(self):
        s = self.prepare()
        before = (s.state / "app.env").read_bytes()
        with self.assertRaises(installer.InstallError):
            s.prepare(self.args)
        self.assertEqual(before, (s.state / "app.env").read_bytes())

    def test_all_operational_commands_reject_conflicting_shell_settings_before_docker(self):
        for key in ["COMPOSE_PROJECT_NAME", "DOCKER_HOST", "DOCKER_CONTEXT", "SECRET_KEY_BASE", "DATABASE_URL"]:
            with self.subTest(key=key), patch.dict(os.environ, {key: "do-not-use"}):
                with self.assertRaises(installer.InstallError):
                    self.subject.execute(self.operation("stop"))
                self.assertEqual([], self.subject.calls)

    def test_invalid_ports_refused_without_creating_state(self):
        self.port.stop()
        for value in [-1, 0, 80, 65536]:
            with self.subTest(value=value), self.assertRaises(installer.InstallError):
                self.subject.port_available(value)
        self.assertFalse(self.subject.state.exists())
        self.port.start()

    def test_busy_port_is_not_reused(self):
        self.port.stop()
        with socket.socket() as held:
            held.bind(("127.0.0.1", 0))
            with self.assertRaises(installer.InstallError):
                self.subject.port_available(held.getsockname()[1])
        self.port.start()

    def test_parallel_command_is_refused_by_actual_file_lock(self):
        first = self.subject.lock()
        try:
            with self.assertRaises(installer.InstallError):
                DockerDouble(self.root).lock()
        finally:
            os.close(first)

    def test_changed_daemon_is_rejected_before_any_service_mutation(self):
        s = self.prepare()
        s.calls.clear()
        s.daemon_id = "different-daemon"
        with self.assertRaises(installer.InstallError):
            s.execute(self.operation("stop"))
        self.assertFalse(any(name.startswith("worker-") or name == "stop" for name, _ in s.calls))

    def test_modified_or_symlink_private_configuration_is_refused(self):
        s = self.prepare()
        app = s.state / "app.env"
        app.write_text(app.read_text() + "DO_NOT_ADOPT=changed\n")
        with self.assertRaises(installer.InstallError):
            s.load()
        app.unlink()
        protected = self.root / "unrelated-secret"
        protected.write_text("unchanged")
        app.symlink_to(protected)
        with self.assertRaises(OSError):
            s.load()
        self.assertEqual("unchanged", protected.read_text())

    def test_resume_after_build_error_preserves_project_and_secrets(self):
        s = self.prepare()
        identity = s.config["project"]
        before = (s.state / "app.env").read_bytes()
        s.fail = "build"
        with self.assertRaises(installer.InstallError):
            s.resume()
        self.assertEqual("building", s.config["stage"])
        s.fail = None
        with contextlib.redirect_stdout(io.StringIO()):
            s.execute(self.operation("resume"))
        self.assertEqual("running", s.config["stage"])
        self.assertEqual(identity, s.config["project"])
        self.assertEqual(before, (s.state / "app.env").read_bytes())
        for name, args in s.calls:
            if "compose" in args and name != "compose-version":
                self.assertIn(identity, args)
                self.assertIn("unix:///var/run/docker.sock", args)
                self.assertNotIn(before.decode(), str(args))

    def test_resume_after_db_failure_preserves_data_identity_and_does_not_rebuild(self):
        s = self.prepare()
        s.fail = "database-prepare"
        with self.assertRaises(installer.InstallError):
            s.resume()
        self.assertEqual("built", s.config["stage"])
        s.calls.clear()
        s.fail = None
        with contextlib.redirect_stdout(io.StringIO()):
            s.execute(self.operation("resume"))
        self.assertNotIn("build", [name for name, _ in s.calls])
        self.assertEqual("running", s.config["stage"])

    def test_partial_secret_write_recovers_without_replacing_existing_app_secrets(self):
        real = installer.private_file
        def interrupt(path, content, exclusive=False):
            if Path(path).name == "db.env":
                raise OSError("Controlled interruption")
            return real(path, content, exclusive)
        with patch.object(installer, "private_file", side_effect=interrupt):
            with self.assertRaises(OSError):
                self.subject.prepare(self.args)
        before = (self.subject.state / "app.env").read_bytes()
        with contextlib.redirect_stdout(io.StringIO()):
            self.subject.execute(self.operation("resume"))
        self.assertEqual(before, (self.subject.state / "app.env").read_bytes())
        self.assertEqual("running", self.subject.config["stage"])

    def test_shutdown_orders_quiet_then_drain_then_stop(self):
        s = self.prepare()
        s.calls.clear()
        s.execute(self.operation("stop"))
        names = [name for name, _ in s.calls]
        self.assertLess(names.index("worker-quiet"), names.index("worker-drain"))
        self.assertLess(names.index("worker-drain"), names.index("stop"))
        stop = next(args for name, args in s.calls if name == "stop")
        self.assertIn("90", stop)

    def test_failed_drain_does_not_stop_busy_workers(self):
        s = self.prepare()
        s.fail = "worker-drain"
        with self.assertRaises(installer.InstallError):
            s.execute(self.operation("stop"))
        self.assertNotIn("stop", [name for name, _ in s.calls])

    def test_resume_recovers_a_worker_left_quiet_after_failed_drain(self):
        s = self.prepare()
        s.config["stage"] = "running"
        s.config["image_id"] = "sha256:" + "d" * 64
        s.save()
        s.fail = "worker-drain"
        with self.assertRaises(installer.InstallError):
            s.execute(self.operation("stop"))
        self.assertTrue(json.loads((s.state / "config.json").read_text())["worker_quiet"])
        s.fail = None
        s.calls.clear()
        with contextlib.redirect_stdout(io.StringIO()):
            s.execute(self.operation("resume"))
        names = [name for name, _ in s.calls]
        self.assertLess(names.index("worker-drain"), names.index("worker-stop"))
        self.assertLess(names.index("worker-stop"), names.index("services-start"))
        self.assertFalse(s.config["worker_quiet"])

    def test_resume_after_worker_already_stopped_clears_quiet_state_and_starts_services(self):
        s = self.prepare()
        s.config.update(stage="running", worker_quiet=True, image_id="sha256:" + "d" * 64)
        s.save()
        s.worker_active = False
        s.calls.clear()
        with contextlib.redirect_stdout(io.StringIO()):
            s.execute(self.operation("resume"))
        names = [name for name, _ in s.calls]
        self.assertNotIn("worker-drain", names)
        self.assertIn("services-start", names)
        self.assertFalse(s.config["worker_quiet"])

    def test_quiet_intent_is_durable_before_the_signal_and_resume_resends_it(self):
        s = self.prepare()
        s.config["stage"] = "running"
        s.config["image_id"] = "sha256:" + "d" * 64
        s.save()
        s.fail = "worker-quiet"
        with self.assertRaises(installer.InstallError):
            s.execute(self.operation("stop"))
        self.assertTrue(json.loads((s.state / "config.json").read_text())["worker_quiet"])
        s.fail = None
        s.calls.clear()
        with contextlib.redirect_stdout(io.StringIO()):
            s.execute(self.operation("resume"))
        names = [name for name, _ in s.calls]
        self.assertLess(names.index("worker-quiet"), names.index("worker-drain"))
        self.assertLess(names.index("worker-drain"), names.index("services-start"))

    def test_stop_is_safe_when_worker_is_already_stopped(self):
        s = self.prepare()
        s.worker_active = False
        s.calls.clear()
        s.execute(self.operation("stop"))
        names = [name for name, _ in s.calls]
        self.assertNotIn("worker-quiet", names)
        self.assertNotIn("worker-drain", names)
        self.assertIn("stop", names)

    def test_recreate_drains_before_replacing_containers_and_preserves_secrets(self):
        s = self.prepare()
        with contextlib.redirect_stdout(io.StringIO()):
            s.resume()
        before = (s.state / "app.env").read_bytes()
        s.calls.clear()
        with contextlib.redirect_stdout(io.StringIO()):
            s.execute(self.operation("recreate"))
        names = [name for name, _ in s.calls]
        self.assertLess(names.index("worker-drain"), names.index("stop"))
        self.assertLess(names.index("stop"), names.index("services-start"))
        start = next(args for name, args in s.calls if name == "services-start")
        self.assertIn("--force-recreate", start)
        self.assertFalse(any("down" in args or "prune" in args for _, args in s.calls))
        self.assertEqual(before, (s.state / "app.env").read_bytes())

    def test_start_refuses_retargeted_image_before_starting_services(self):
        s = self.prepare()
        with contextlib.redirect_stdout(io.StringIO()):
            s.resume()
        original_run = s.run
        def wrong_image(name, args, capture=False):
            if name == "selected-image":
                return "sha256:" + "0" * 64
            return original_run(name, args, capture)
        s.calls.clear()
        with patch.object(s, "run", side_effect=wrong_image):
            with self.assertRaises(installer.InstallError):
                s.execute(self.operation("start"))
        self.assertNotIn("services-start", [name for name, _ in s.calls])

    def test_verify_binds_both_running_images_and_full_source_identity(self):
        s = self.prepare()
        with contextlib.redirect_stdout(io.StringIO()):
            s.resume()
            s.execute(self.operation("verify"))
        verify = next(args for name, args in s.calls if name == "runtime-verify")
        self.assertEqual(["a" * 40, "b" * 40, "c" * 64], verify[-3:])
        self.assertEqual(2, sum(name == "runtime-image" for name, _ in s.calls))
        s.config["image_id"] = "sha256:" + "0" * 64
        s.save()
        s.calls.clear()
        with self.assertRaises(installer.InstallError):
            s.execute(self.operation("verify"))
        self.assertNotIn("runtime-verify", [name for name, _ in s.calls])

    def production_configuration(self):
        self.args.profile = "production"
        self.args.domain = "community.example.org"
        return self.prepare()

    def config_input(self, content):
        path = self.root / "operator.env"
        installer.private_file(path, content)
        return path

    def test_configuration_accepts_literal_smtp_secrets_without_touching_generated_keys(self):
        s = self.production_configuration()
        before = (s.state / "app.env").read_text()
        incoming = self.config_input("SMTP_ADDRESS=smtp.example.org\nSMTP_PASSWORD=literal$not_a_variable`not_a_command`\n")
        with contextlib.redirect_stdout(io.StringIO()) as output:
            s.configure(incoming)
        after = (s.state / "app.env").read_text()
        for line in before.splitlines():
            self.assertIn(line, after.splitlines())
        self.assertIn("SMTP_PASSWORD=literal$not_a_variable`not_a_command`", after)
        self.assertNotIn("literal$", output.getvalue())
        s.load()

    def test_configuration_rejects_boundary_changes_before_writing(self):
        s = self.production_configuration()
        before = (s.state / "app.env").read_bytes()
        for content in ("DATABASE_URL=foreign", "MI_LOCAL_HTTP=true", "SMTP_PORT=0", "SMTP_ADDRESS=a\nSMTP_ADDRESS=b"):
            with self.subTest(content=content), self.assertRaises(installer.InstallError):
                s.configure(self.config_input(content))
            self.assertEqual(before, (s.state / "app.env").read_bytes())

    def test_demo_profile_refuses_runtime_smtp_reconfiguration(self):
        s = self.prepare()
        with self.assertRaises(installer.InstallError):
            s.configure(self.config_input("SMTP_ADDRESS=foreign"))

    def test_configuration_reconciles_interruption_before_replacing_env(self):
        s = self.production_configuration()
        original = s.reconcile_configuration
        with patch.object(s, "reconcile_configuration", side_effect=OSError("Controlled interruption")):
            with self.assertRaises(OSError):
                s.configure(self.config_input("SMTP_ADDRESS=smtp.example.org"))
        self.assertIn("configuration_pending", s.config)
        s.load()
        self.assertNotIn("configuration_pending", s.config)
        self.assertIn("SMTP_ADDRESS=smtp.example.org", (s.state / "app.env").read_text())

    def test_configuration_reconciles_interruption_after_replacing_env(self):
        s = self.production_configuration()
        save = s.save
        writes = 0
        def interrupt():
            nonlocal writes
            writes += 1
            if writes == 2:
                raise OSError("Controlled completion interruption")
            return save()
        with patch.object(s, "save", side_effect=interrupt):
            with self.assertRaises(OSError):
                s.configure(self.config_input("SMTP_ADDRESS=smtp.example.org"))
        self.assertIn("SMTP_ADDRESS=smtp.example.org", (s.state / "app.env").read_text())
        s.load()
        self.assertNotIn("configuration_pending", s.config)

    def test_foreign_volume_is_not_adopted_by_resume(self):
        s = self.prepare()
        s.volume_rows = s.config["project"] + "_postgres\tsomebody-else"
        with self.assertRaises(installer.InstallError):
            s.execute(self.operation("resume"))
        self.assertNotIn("data-services", [name for name, _ in s.calls])

    def test_production_refuses_demo_capture_before_creating_state(self):
        self.args.profile = "production"
        self.args.domain = "community.example.org"
        self.args.capture_phone = True
        with self.assertRaises(installer.InstallError):
            self.subject.prepare(self.args)
        self.assertFalse(self.subject.state.exists())


class BuildContextBoundaryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Synthetic installation test")
        self.git("config", "user.email", "test@example.invalid")
        (self.root / ".gitignore").write_text(".mi-install/\n.mi-install.lock\n.env*\n")
        (self.root / "Gemfile.lock").write_text("GIT\n  remote: https://github.com/example/engine.git\n  revision: " + "b" * 40 + "\n  specs:\n    decidim-bih (0.4.0)\n")
        (self.root / "app.rb").write_text("# committed example\n")
        self.git("add", ".")
        self.git("commit", "-qm", "Synthetic source")
        self.subject = installer.Installation(self.root)
        self.subject.state.mkdir(mode=0o700)
        self.subject.config = {"project": "mi-" + "a" * 16, "source": self.subject.source()}

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True)

    def test_ignored_runtime_secret_is_absent_from_actual_git_build_archive(self):
        (self.root / ".env.operator").write_text("do-not-copy")
        (self.subject.state / "app.env").write_text("also-do-not-copy")
        self.subject.context()
        context = self.subject.state / "build-context"
        self.assertTrue((context / "app.rb").exists())
        self.assertFalse((context / ".env.operator").exists())
        self.assertFalse((context / ".mi-install").exists())

    def test_uncommitted_source_is_refused(self):
        (self.root / "app.rb").write_text("# uncommitted change")
        with self.assertRaises(installer.InstallError):
            self.subject.source()

    def test_symlink_context_is_refused_without_touching_unrelated_directory(self):
        unrelated = self.root / "operator-data"
        unrelated.mkdir()
        marker = unrelated / "keep.txt"
        marker.write_text("keep")
        (self.subject.state / "build-context").symlink_to(unrelated, target_is_directory=True)
        with self.assertRaises(installer.InstallError):
            self.subject.context()
        self.assertEqual("keep", marker.read_text())

    def test_private_file_permissions_are_enforced(self):
        target = self.root / "private-config"
        installer.private_file(target, "test-only")
        target.chmod(0o644)
        with self.assertRaises(installer.InstallError):
            installer.read_private(target)


if __name__ == "__main__":
    unittest.main()
