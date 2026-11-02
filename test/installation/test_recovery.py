"""Recovery state-machine and real filesystem tests, not Docker acceptance."""
import argparse
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "script/lib"))
from mi_installer import InstallError, private_file
from mi_recovery import Recovery, digest, filtered_toc
from test_installer import DockerDouble


PROBE = {"format": 1, "redis_control_sha256": "e" * 64, "database": {"synthetic": {"count": 1, "sha256": "a" * 64}}, "storage": {"files": 1, "bytes": 10, "sha256": "b" * 64}}


class RecoveryInstallation(DockerDouble):
    def run(self, name, args, capture=False):
        result = super().run(name, args, capture)
        if name.startswith("running-"):
            return "e" * 64
        if name == "recovery-volumes":
            return "\n".join(self.config["project"] + "_" + item for item in ("postgres", "redis", "storage"))
        if name == "restore-image-identity":
            return self.config["image_id"]
        if name == "restore-queue-review":
            return json.dumps({"status": "quarantined_queue_inventory", "queues": []})
        return result


class RecoveryDouble(Recovery):
    mismatch = False

    def transfer(self, name, args, output=None, input_path=None, input_bytes=None):
        self.i.calls.append((name, args))
        if self.i.fail == name:
            raise InstallError("Controlled recovery interruption")
        if name == "restore-toc-upload":
            self.filtered_toc = input_bytes.decode()
        if output:
            if name == "backup-volumes.tar":
                with tarfile.open(output, "w") as archive:
                    for directory in ("storage", "redis"):
                        item = tarfile.TarInfo(directory)
                        item.type = tarfile.DIRTYPE
                        archive.addfile(item)
                output.chmod(0o600)
            elif name == "restore-toc":
                private_file(output, "1; 3079 16400 EXTENSION - ltree postgres\n2; 0 0 COMMENT - EXTENSION ltree postgres\n3; 2615 2200 SCHEMA - public pg_database_owner\n4; 1259 16401 TABLE public synthetic mi_app\n")
            else:
                private_file(output, "synthetic archive " + name)

    def probe(self, prepare=False):
        result = copy.deepcopy(PROBE)
        if self.mismatch:
            result["storage"]["sha256"] = "c" * 64
        return result


class RecoverySafetyTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.parent = Path(self.temporary.name)
        self.root = self.parent / "source"
        self.root.mkdir()
        self.subject = RecoveryInstallation(self.root)
        self.recovery = RecoveryDouble(self.subject)
        self.environment = patch.dict(os.environ, {"PATH": "/usr/bin:/bin", "HOME": str(self.parent)}, clear=True)
        self.environment.start()
        self.disk = patch("mi_installer.shutil.disk_usage", return_value=type("Disk", (), {"free": 30 * 1024**3})())
        self.disk.start()
        self.port = patch("mi_installer.Installation.port_available")
        self.port.start()
        args = argparse.Namespace(profile="demo", domain=None, web_port=3100, mail_port=8125, docker_host=None, capture_phone=True)
        with contextlib.redirect_stdout(io.StringIO()):
            self.subject.prepare(args)
            self.subject.resume()
        self.subject.calls.clear()

    def tearDown(self):
        self.port.stop()
        self.disk.stop()
        self.environment.stop()
        self.temporary.cleanup()

    def backup(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.recovery.backup()
        return Path(self.subject.config["last_backup"]["path"])

    def target(self):
        root = self.parent / "target"
        root.mkdir()
        target = RecoveryInstallation(root)
        recovery = RecoveryDouble(target)
        return target, recovery

    def restore_args(self, backup):
        return argparse.Namespace(backup=backup, docker_host=None, web_port=3200, mail_port=8225)

    def test_backup_stops_application_and_redis_before_archiving_and_restarts_after_manifest(self):
        original = (self.subject.state / "app.env").read_bytes()
        directory = self.backup()
        names = [name for name, _ in self.subject.calls]
        self.assertLess(names.index("backup-worker-quiet"), names.index("backup-worker-drain"))
        self.assertLess(names.index("backup-application-stop"), names.index("backup-database.dump"))
        self.assertLess(names.index("backup-redis-stop"), names.index("backup-volumes.tar"))
        self.assertLess(names.index("backup-app-image.tar"), names.index("services-start"))
        self.assertEqual(original, (directory / "app.env").read_bytes())
        self.assertNotIn("maintenance", self.subject.config)
        self.recovery.validate_backup(directory)
        self.assertNotIn("credentials.json", [path.name for path in directory.iterdir()])

    def test_failed_archive_keeps_services_quiesced_and_resume_keeps_keys(self):
        original = (self.subject.state / "app.env").read_bytes()
        self.subject.fail = "backup-volumes.tar"
        with self.assertRaises(InstallError):
            self.recovery.backup()
        self.assertEqual("quiesced", self.subject.config["maintenance"]["phase"])
        self.assertNotIn("services-start", [name for name, _ in self.subject.calls])
        completed_db = Path(self.subject.config["maintenance"]["path"]) / "database.dump"
        before = digest(completed_db)
        self.subject.fail = None
        self.subject.calls.clear()
        directory = self.backup()
        self.assertNotIn("backup-database.dump", [name for name, _ in self.subject.calls])
        self.assertEqual(before, digest(directory / "database.dump"))
        self.assertEqual(original, (self.subject.state / "app.env").read_bytes())

    def test_existing_backup_destination_is_not_overwritten(self):
        destination = self.parent / "existing"
        destination.mkdir(mode=0o700)
        private_file(destination / "keep", "synthetic control")
        with self.assertRaises(InstallError):
            self.recovery.backup(destination)
        self.assertEqual("synthetic control", (destination / "keep").read_text())
        self.assertNotIn("backup-worker-quiet", [name for name, _ in self.subject.calls])

    def test_restore_uses_new_resources_preserves_keys_and_never_starts_web_or_worker(self):
        directory = self.backup()
        target, recovery = self.target()
        with contextlib.redirect_stdout(io.StringIO()):
            recovery.restore(self.restore_args(directory))
        self.assertNotEqual(self.subject.config["project"], target.config["project"])
        self.assertEqual(self.subject.config["project"], target.config["installation_id"])
        self.assertEqual((self.subject.state / "app.env").read_bytes(), (target.state / "app.env").read_bytes())
        self.assertTrue(target.config["restore_quarantine"])
        self.assertEqual("verified", target.config["maintenance"]["phase"])
        names = [name for name, _ in target.calls]
        self.assertNotIn("services-start", names)
        self.assertNotIn("build", names)
        self.assertNotIn("database-prepare", names)
        command = next(args for name, args in target.calls if name == "restore-database")
        self.assertIn("--role=mi_app", command)
        self.assertIn("--clean", command)
        self.assertIn(str(target.root / "installation/compose.restore.yml"), command)
        self.assertNotIn("EXTENSION", recovery.filtered_toc)
        self.assertNotIn("SCHEMA", recovery.filtered_toc)
        self.assertIn("TABLE public synthetic", recovery.filtered_toc)
        target.load()

    def test_corrupt_backup_is_refused_before_creating_target_state(self):
        directory = self.backup()
        (directory / "database.dump").write_bytes(b"changed")
        target, recovery = self.target()
        with self.assertRaises(InstallError):
            recovery.restore(self.restore_args(directory))
        self.assertFalse(target.state.exists())
        self.assertEqual([], target.calls)

    def test_malformed_manifest_is_refused_before_target_mutations(self):
        directory = self.backup()
        manifest = directory / "manifest.json"
        manifest.write_text("[]")
        target, recovery = self.target()
        with self.assertRaises(InstallError):
            recovery.restore(self.restore_args(directory))
        self.assertFalse(target.state.exists())
        self.assertEqual([], target.calls)

    def test_restore_refuses_existing_installation_without_writing(self):
        directory = self.backup()
        original = (self.subject.state / "app.env").read_bytes()
        with self.assertRaises(InstallError):
            self.recovery.restore(self.restore_args(directory))
        self.assertEqual(original, (self.subject.state / "app.env").read_bytes())

    def test_mismatched_photo_probe_keeps_restore_quarantined(self):
        directory = self.backup()
        target, recovery = self.target()
        recovery.mismatch = True
        with self.assertRaises(InstallError):
            recovery.restore(self.restore_args(directory))
        self.assertTrue(target.config["restore_quarantine"])
        self.assertEqual("database-restored", target.config["maintenance"]["phase"])
        self.assertNotIn("services-start", [name for name, _ in target.calls])

    def test_failed_database_restore_resumes_only_the_owned_import(self):
        directory = self.backup()
        target, recovery = self.target()
        target.fail = "restore-database"
        with self.assertRaises(InstallError):
            recovery.restore(self.restore_args(directory))
        self.assertEqual("volumes-restored", target.config["maintenance"]["phase"])
        original = (target.state / "app.env").read_bytes()
        target.fail = None
        target.calls.clear()
        with contextlib.redirect_stdout(io.StringIO()):
            recovery.resume_restore()
        self.assertNotIn("restore-volumes", [name for name, _ in target.calls])
        self.assertEqual(original, (target.state / "app.env").read_bytes())
        self.assertTrue(target.config["restore_quarantine"])

    def test_activation_requires_explicit_review_and_preserves_the_queue(self):
        directory = self.backup()
        target, recovery = self.target()
        with contextlib.redirect_stdout(io.StringIO()):
            recovery.restore(self.restore_args(directory))
        with self.assertRaises(InstallError):
            recovery.activate(False)
        self.assertTrue(target.config["restore_quarantine"])
        with contextlib.redirect_stdout(io.StringIO()):
            recovery.activate(True)
        self.assertFalse(target.config["restore_quarantine"])
        self.assertNotIn("maintenance", target.config)
        self.assertIn("services-start", [name for name, _ in target.calls])
        self.assertFalse(any("FLUSH" in " ".join(args) for _, args in target.calls))

    def test_quarantined_installation_refuses_normal_start_and_configure(self):
        directory = self.backup()
        target, recovery = self.target()
        with contextlib.redirect_stdout(io.StringIO()):
            recovery.restore(self.restore_args(directory))
        for command in ("start", "restart", "verify", "admin", "configure", "demo-content"):
            args = argparse.Namespace(command=command, profile=None, domain=None, web_port=None, mail_port=None, docker_host=None, capture_phone=False, env_file=None)
            target.calls.clear()
            with self.subTest(command=command), self.assertRaises(InstallError):
                target.execute(args)
            self.assertNotIn("services-start", [name for name, _ in target.calls])

    def test_unsupported_extensions_are_not_silently_skipped(self):
        with self.assertRaises(InstallError):
            filtered_toc("1; 3079 16400 EXTENSION - custom_extension postgres\n")
        result = filtered_toc("1; 3079 16400 EXTENSION - ltree postgres\n2; 1259 16401 TABLE public example mi_app\n")
        self.assertNotIn("EXTENSION", result)
        self.assertIn("TABLE public example", result)

    def test_duplicate_archive_file_is_refused(self):
        path = self.parent / "duplicate.tar"
        with tarfile.open(path, "w") as archive:
            archive.addfile(tarfile.TarInfo("storage/example"))
            archive.addfile(tarfile.TarInfo("storage/example"))
        with self.assertRaises(InstallError):
            self.recovery.validate_volume_archive(path)

    def test_tar_traversal_links_and_duplicate_files_are_refused(self):
        for name, kind in [("../outside", tarfile.REGTYPE), ("storage/link", tarfile.SYMTYPE), ("redis/link", tarfile.LNKTYPE)]:
            with self.subTest(name=name):
                path = self.parent / "bad.tar"
                with tarfile.open(path, "w") as archive:
                    item = tarfile.TarInfo(name)
                    item.type = kind
                    archive.addfile(item)
                with self.assertRaises(InstallError):
                    self.recovery.validate_volume_archive(path)

    def test_archive_transfer_streams_bytes_privately_and_keeps_partial_failure(self):
        target = self.parent / "streamed"
        real = Recovery(self.subject)
        real.transfer("synthetic-stream", [sys.executable, "-c", "import sys; sys.stdout.buffer.write(b'PGDMP\\x00synthetic')"], output=target)
        self.assertEqual(b"PGDMP\x00synthetic", target.read_bytes())
        self.assertEqual(0o600, target.stat().st_mode & 0o777)
        broken = self.parent / "broken"
        with self.assertRaises(InstallError):
            real.transfer("synthetic-failure", [sys.executable, "-c", "import sys; sys.stdout.write('partial'); sys.exit(1)"], output=broken)
        self.assertFalse(broken.exists())
        self.assertEqual(b"partial", broken.with_name("broken.part").read_bytes())


if __name__ == "__main__":
    unittest.main()
