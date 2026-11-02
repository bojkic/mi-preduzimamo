"""Private, project-scoped snapshots and an initially quarantined restore.

A checksum/listing is structural evidence. Only a completed independent restore
and matching application/photo probes establish recovery for that environment.
"""
import copy
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import stat
import subprocess
import tarfile
from datetime import datetime, timezone

from mi_installer import InstallError, private_file, read_private, require


FILES = {"database.dump", "volumes.tar", "app-image.tar", "app.env", "db.env", "compose.env", "probe.json"}


def digest(path):
    value = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def owned_file(path):
    meta = path.lstat()
    require(stat.S_ISREG(meta.st_mode) and meta.st_uid == os.getuid() and meta.st_mode & 0o077 == 0,
            "Backup fajl mora biti regularan, privatan i pripadati operateru.")


def owned_directory(path):
    meta = path.lstat()
    require(stat.S_ISDIR(meta.st_mode) and meta.st_uid == os.getuid() and meta.st_mode & 0o077 == 0,
            "Backup direktorijum mora biti privatan i pripadati operateru.")


def atomic_private(path, content):
    temporary = path.with_name(path.name + ".next")
    if temporary.exists() or temporary.is_symlink():
        owned_file(temporary)
    private_file(temporary, content)
    os.replace(temporary, path)
    fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def filtered_toc(listing):
    rows = []
    for row in listing.splitlines():
        extension = re.search(r"; \d+ \d+ EXTENSION - (\S+)", row)
        require(not extension or extension[1] in {"plpgsql", "ltree", "pg_trgm"}, "Backup koristi nepodržanu ekstenziju; potreban je pregled bootstrap-a.")
        if not re.search(r"; \d+ \d+ (?:EXTENSION |COMMENT - EXTENSION |SCHEMA - public |COMMENT - SCHEMA public )", row):
            rows.append(row)
    return "\n".join(rows) + "\n"


class Recovery:
    def __init__(self, installation):
        self.i = installation

    def compose_args(self, *args):
        return self.i.compose_args(*args)

    def transfer(self, name, args, output=None, input_path=None, input_bytes=None):
        """Stream large archives directly, never through logs or process RAM."""
        require(not (input_path is not None and input_bytes is not None), "Nejednoznačan ulaz arhive.")
        logs = self.i.state / "logs"
        logs.mkdir(mode=0o700, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%f")
        log = logs / (stamp + "-" + name + ".log")
        errfd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(errfd, "wb") as errors, ExitStack() as opened:
            source = None
            target = None
            if input_path is not None:
                owned_file(input_path)
                source = opened.enter_context(open(input_path, "rb"))
            if output is not None:
                if output.exists() or output.is_symlink():
                    owned_file(output)
                temporary = output.with_name(output.name + ".part")
                if temporary.exists() or temporary.is_symlink():
                    owned_file(temporary)
                fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
                target = opened.enter_context(os.fdopen(fd, "wb"))
            proc = subprocess.run(args, cwd=self.i.root, env=self.i.environment,
                                  stdin=source, input=input_bytes, stdout=target or errors, stderr=errors)
            errors.flush()
            os.fsync(errors.fileno())
            require(proc.returncode == 0, "Recovery korak " + name + " nije uspio; privatni log je sačuvan. Koristite resume, ne novi install.")
            if target:
                target.flush()
                os.fsync(target.fileno())
                target.close()
                os.replace(temporary, output)
                directory = os.open(output.parent, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)

    def volume_command(self, mode):
        project = self.i.config["project"]
        args = self.i.docker_args("run", "--rm", "--network", "none", "--read-only", "--cap-drop", "ALL",
                                  "--cap-add", "DAC_READ_SEARCH" if mode == "backup" else "DAC_OVERRIDE",
                                  "--security-opt", "no-new-privileges", "--user", "0:0")
        if mode == "restore":
            args += ["--cap-add", "CHOWN", "--cap-add", "FOWNER", "--interactive"]
        for suffix in ("storage", "redis"):
            mount = "type=volume,src=" + project + "_" + suffix + ",dst=/snapshot/" + suffix
            args += ["--mount", mount + (",readonly" if mode == "backup" else "")]
        args += ["--entrypoint", "tar", self.i.config["image_id"], "-C", "/snapshot"]
        return args + (["-cf", "-", "storage", "redis"] if mode == "backup" else ["--extract", "--same-owner", "--file", "-"])

    def required_volumes(self):
        project = self.i.config["project"]
        rows = self.i.run("recovery-volumes", self.i.docker_args("volume", "ls", "--filter", "label=com.docker.compose.project=" + project,
                          "--format", '{{.Name}}'), capture=True).splitlines()
        require({project + "_" + name for name in ("postgres", "redis", "storage")}.issubset(rows),
                "Nedostaje volumen ove instalacije; ne pravim zamjensku praznu kopiju.")

    def running(self, service):
        return bool(self.i.compose("running-" + service, "ps", "--status", "running", "--quiet", service, capture=True))

    def probe(self, prepare=False):
        options = ["prepare"] if prepare else []
        raw = self.i.compose("recovery-probe", "run", "--rm", "--no-deps", "app", "bin/rails", "runner", "installation/recovery_probe.rb", *options, capture=True)
        value = json.loads(raw.splitlines()[-1])
        require(value.get("format") == 1 and isinstance(value.get("database"), dict) and isinstance(value.get("storage"), dict), "Nepoznat recovery probe format.")
        require(isinstance(value.get("redis_control_sha256"), str) and re.fullmatch(r"[0-9a-f]{64}", value["redis_control_sha256"]), "Redis recovery kontrola nije potvrđena.")
        return value

    def artifact(self, name, command):
        record = self.i.config["maintenance"]
        target = Path(record["path"]) / name
        if target.exists() or target.is_symlink():
            owned_file(target)
        else:
            self.transfer("backup-" + name, command, output=target)
        actual = digest(target)
        expected = record["files"].get(name)
        require(expected is None or expected["sha256"] == actual, "Sačuvana backup arhiva se promijenila; odbijeno bez prepisivanja.")
        record["files"][name] = {"sha256": actual, "size": target.stat().st_size}
        self.i.save()

    def backup(self, output=None, restart=True):
        self.i.daemon()
        require(not self.i.config.get("restore_quarantine"), "Karantin prvo pregledajte; ne pravim novu kopiju nepotvrđenog restore-a.")
        if not self.i.config.get("maintenance"):
            require(self.i.config.get("stage") == "running" and self.running("app") and self.running("worker"), "Backup počinje nad pokrenutom i provjerenom instalacijom.")
            self.required_volumes()
            self.i.verify_running()
            require(re.fullmatch(r"sha256:[0-9a-f]{64}", self.i.config.get("image_id", "")), "Nedostaje tačan image identitet.")
            if output is None:
                parent = self.i.state / "backups"
                parent.mkdir(mode=0o700, exist_ok=True)
                output = parent / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S") + "-" + secrets.token_hex(4))
            output = Path(output).absolute()
            owned_directory(output.parent)
            require(self.i.root not in output.parents or self.i.state in output.parents, "Backup odredište mora biti van izvornog koda ili unutar privatnog .mi-install direktorijuma.")
            require(not output.exists() and not output.is_symlink(), "Backup odredište već postoji; ništa nije prepisano.")
            output.mkdir(mode=0o700)
            self.i.config["maintenance"] = {"kind": "backup", "phase": "quiescing", "path": str(output), "files": {}}
            self.i.save()
        record = self.i.config["maintenance"]
        require(record["kind"] == "backup" and (output is None or Path(output).absolute() == Path(record["path"])), "Druga maintenance operacija je u toku.")
        directory = Path(record["path"])
        owned_directory(directory)
        if record["phase"] == "quiescing":
            if self.running("worker"):
                self.i.compose("backup-worker-quiet", "kill", "--signal", "TSTP", "worker")
                self.i.config["worker_quiet"] = True
                self.i.save()
                self.i.compose("backup-worker-drain", "exec", "-T", "worker", "bundle", "exec", "ruby", "installation/drain.rb")
            self.i.compose("backup-application-stop", "stop", "--timeout", "90", "app", "worker")
            self.i.config["worker_quiet"] = False
            self.i.compose("backup-redis-start", "up", "-d", "--wait", "redis")
            probe = self.probe(prepare=True)
            atomic_private(directory / "probe.json", json.dumps(probe, sort_keys=True) + "\n")
            self.i.compose("backup-redis-save", "exec", "-T", "redis", "redis-cli", "SAVE")
            self.i.compose("backup-redis-stop", "stop", "--timeout", "90", "redis")
            record["phase"] = "quiesced"
            self.i.save()
        if record["phase"] == "quiesced":
            self.required_volumes()
            self.artifact("database.dump", self.compose_args("exec", "-T", "postgres", "pg_dump", "--format=custom", "--no-owner", "--no-acl", "-U", "postgres", "-d", "mi_platform"))
            self.artifact("volumes.tar", self.volume_command("backup"))
            self.artifact("app-image.tar", self.i.docker_args("image", "save", self.i.config["image_id"]))
            for name in ("app.env", "db.env", "compose.env"):
                target = directory / name
                if not target.exists():
                    private_file(target, read_private(self.i.state / name), exclusive=True)
                owned_file(target)
                require(digest(target) == self.i.config["files"][name], "Backup konfiguracija se ne poklapa sa instalacijom.")
                record["files"][name] = {"sha256": digest(target), "size": target.stat().st_size}
            record["files"]["probe.json"] = {"sha256": digest(directory / "probe.json"), "size": (directory / "probe.json").stat().st_size}
            saved = copy.deepcopy(self.i.config)
            saved.pop("maintenance", None)
            saved.pop("upgrade", None)
            saved.pop("services_stopped_for_upgrade", None)
            saved["worker_quiet"] = False
            manifest = {"format": 1, "created_at": datetime.now(timezone.utc).isoformat(), "configuration": saved, "files": record["files"],
                        "boundary": "Quiesced logical DB, stopped Redis/uploads, exact app image and secrets; restore acceptance is separate."}
            atomic_private(directory / "manifest.json", json.dumps(manifest, indent=2) + "\n")
            record["phase"] = "archived"
            self.i.save()
        require(record["phase"] == "archived", "Nepoznata backup faza; sačuvajte postojeće podatke.")
        self.validate_backup(directory)
        if restart:
            self.i.resume()
        else:
            self.i.config["services_stopped_for_upgrade"] = True
        self.i.config["last_backup"] = {"path": str(directory), "manifest_sha256": digest(directory / "manifest.json"), "source": self.i.config["source"]}
        del self.i.config["maintenance"]
        self.i.save()
        print("Backup je sačuvan privatno: " + str(directory) + ". Ovo još nije dokaz restore-a.")

    def validate_backup(self, directory):
        owned_directory(directory)
        manifest = json.loads(read_private(directory / "manifest.json"))
        require(isinstance(manifest, dict) and manifest.get("format") == 1 and isinstance(manifest.get("files"), dict), "Nepotpun ili nepoznat backup manifest.")
        require(set(manifest["files"]) == FILES and isinstance(manifest.get("configuration"), dict), "Nepotpun backup inventar ili konfiguracija.")
        saved = manifest["configuration"]
        required = {"source", "profile", "project", "image_id", "runtime_uid", "ports", "domain", "files"}
        require(required.issubset(saved), "Nedostaju obavezna konfiguraciona polja kopije.")
        require(saved.get("format") == self.i.FORMAT and saved["profile"] in ("demo", "production"), "Nepodržan konfiguracioni format/profil kopije.")
        require(isinstance(saved["project"], str) and re.fullmatch(r"mi-[0-9a-f]{16}", saved["project"]), "Neispravan project kopije.")
        identity = saved.get("installation_id", saved["project"])
        require(isinstance(identity, str) and re.fullmatch(r"mi-[0-9a-f]{16}", identity), "Neispravan DB identitet kopije.")
        require(isinstance(saved["image_id"], str) and re.fullmatch(r"sha256:[0-9a-f]{64}", saved["image_id"]), "Neispravan image identitet kopije.")
        source = saved["source"]
        require(isinstance(source, dict) and set(source) == {"app_sha", "engine_sha", "lock_sha256"}, "Nepoznat izvorni par kopije.")
        require(all(isinstance(source[key], str) and re.fullmatch(r"[0-9a-f]{" + str(size) + r"}", source[key]) for key, size in (("app_sha", 40), ("engine_sha", 40), ("lock_sha256", 64))), "Neispravni izvorni hashovi kopije.")
        require(isinstance(saved["ports"], dict) and set(saved["ports"]) == {"web", "mail"}, "Neispravni portovi kopije.")
        require(all(type(value) is int and 1024 <= value <= 65535 for value in saved["ports"].values()), "Neispravan broj porta kopije.")
        require(type(saved["runtime_uid"]) is int and 1000 <= saved["runtime_uid"] <= 2147483647, "Neispravan runtime UID kopije.")
        require(isinstance(saved["domain"], str) and re.fullmatch(r"[a-z0-9.-]{1,253}", saved["domain"]), "Neispravan host kopije.")
        require(isinstance(saved["files"], dict) and set(saved["files"]) == {"app.env", "db.env", "compose.env"}, "Neispravni privatni fajlovi kopije.")
        for name, expected in manifest["files"].items():
            require(isinstance(expected, dict) and set(expected) == {"size", "sha256"} and type(expected["size"]) is int and expected["size"] >= 0, "Neispravan zapis backup fajla.")
            require(isinstance(expected["sha256"], str) and re.fullmatch(r"[0-9a-f]{64}", expected["sha256"]), "Neispravan checksum zapis.")
            target = directory / name
            owned_file(target)
            require(target.stat().st_size == expected["size"] and digest(target) == expected["sha256"], "Backup checksum nije važeći; restore nije pokrenut.")
        require(all(saved["files"][name] == manifest["files"][name]["sha256"] for name in saved["files"]), "Konfiguracioni hashovi kopije nisu usklađeni.")
        return manifest

    def validate_volume_archive(self, path):
        seen = set()
        with tarfile.open(path, "r:") as archive:
            for entry in archive:
                name = PurePosixPath(entry.name)
                require(not name.is_absolute() and ".." not in name.parts and name.parts and name.parts[0] in {"storage", "redis"}, "Neispravna putanja u backup arhivi.")
                require(entry.isdir() or entry.isfile(), "Linkovi i posebni fajlovi nisu podržani u recovery arhivi.")
                require(str(name) not in seen, "Duplikat u recovery arhivi.")
                seen.add(str(name))

    def restore(self, args):
        require(not self.i.state.exists() and not self.i.state.is_symlink(), "Restore zahtijeva novi checkout bez .mi-install; postojeća instalacija nije promijenjena.")
        require(args.backup is not None, "Restore zahtijeva --backup sa privatnim direktorijumom kopije.")
        directory = Path(args.backup).absolute()
        manifest = self.validate_backup(directory)
        self.validate_volume_archive(directory / "volumes.tar")
        saved = manifest["configuration"]
        require(saved["source"] == self.i.source(), "Restore zahtijeva tačan app/engine/lockfile par kopije.")
        require(saved["profile"] in ("demo", "production") and re.fullmatch(r"mi-[0-9a-f]{16}", saved["project"]), "Neispravan profil ili identitet kopije.")
        require(re.fullmatch(r"sha256:[0-9a-f]{64}", saved["image_id"]), "Nedostaje image identitet kopije.")
        require(saved["runtime_uid"] == (os.getuid() if os.getuid() >= 1000 else 1000), "Restore operater mora odgovarati izvornom runtime UID-u; prava se ne mijenjaju automatski.")
        endpoint = args.docker_host or "unix:///var/run/docker.sock"
        require(endpoint.startswith("unix:///") and "\n" not in endpoint, "Restore zahtijeva izričit lokalni Unix Docker socket.")
        ports = {"web": args.web_port or saved["ports"]["web"], "mail": args.mail_port or saved["ports"]["mail"]}
        require(ports["web"] != ports["mail"], "Web i Mailpit port moraju biti različiti.")
        for port in ports.values():
            self.i.port_available(port)
        self.i.state.mkdir(mode=0o700)
        for child in ("docker-client", "private"):
            (self.i.state / child).mkdir(mode=0o700)
        project = "mi-" + secrets.token_hex(8)
        self.i.config = copy.deepcopy(saved)
        self.i.config.pop("last_backup", None)
        self.i.config.update(root=str(self.i.root), project=project, installation_id=saved.get("installation_id", saved["project"]), docker_host=endpoint,
                             ports=ports, restore_quarantine=True, stage="database-ready", resources_cleared=False,
                             maintenance={"kind": "restore", "phase": "prepared", "path": str(directory), "manifest_sha256": digest(directory / "manifest.json")})
        self.i.config.pop("daemon_id", None)
        self.i.save()
        self.restore_configuration()
        self.i.daemon(initial=True)
        self.i.resources(initial=True)
        self.resume_restore()

    def restore_configuration(self):
        record = self.i.config["maintenance"]
        directory = Path(record["path"])
        self.validate_backup(directory)
        require(digest(directory / "manifest.json") == record["manifest_sha256"], "Restore izvor se promijenio.")
        for name in ("app.env", "db.env"):
            target = self.i.state / name
            if not target.exists():
                atomic_private(target, read_private(directory / name))
            require(digest(target) == self.i.config["files"][name], "Vraćene tajne se ne poklapaju; ništa nije regenerisano.")
        c = self.i.config
        value = ("MI_IMAGE=" + c["project"] + "-app:" + c["source"]["app_sha"][:12] + "\nMI_APP_SHA=" + c["source"]["app_sha"] +
                 "\nMI_RUNTIME_UID=" + str(c["runtime_uid"]) + "\nMI_PROFILE=" + c["profile"] + "\nMI_INSTALL_ID=" + c["installation_id"] +
                 "\nMI_WEB_PORT=" + str(c["ports"]["web"]) + "\nMI_MAIL_PORT=" + str(c["ports"]["mail"]) + "\nMI_DOMAIN=" + c["domain"] + "\n")
        target = self.i.state / "compose.env"
        if not target.exists():
            atomic_private(target, value)
        require(read_private(target) == value, "Restore Compose zapis je promijenjen mimo alata.")
        c["files"]["compose.env"] = digest(target)
        self.i.save()

    def resume_restore(self):
        record = self.i.config["maintenance"]
        require(record["kind"] == "restore", "Druga maintenance operacija je u toku.")
        directory = Path(record["path"])
        self.restore_configuration()
        self.i.daemon(initial="daemon_id" not in self.i.config)
        self.i.resources(initial=not self.i.config.get("resources_cleared", False))
        if record["phase"] == "prepared":
            self.transfer("restore-image", self.i.docker_args("image", "load"), input_path=directory / "app-image.tar")
            actual = self.i.run("restore-image-identity", self.i.docker_args("image", "inspect", "--format", "{{.Id}}", self.i.config["image_id"]), capture=True)
            require(actual == self.i.config["image_id"], "Vraćeni image ne odgovara kopiji.")
            image_name = self.i.config["project"] + "-app:" + self.i.config["source"]["app_sha"][:12]
            self.i.run("restore-image-tag", self.i.docker_args("image", "tag", actual, image_name))
            for suffix in ("storage", "redis"):
                self.i.run("restore-volume-" + suffix, self.i.docker_args("volume", "create", "--label", "com.docker.compose.project=" + self.i.config["project"],
                           "--label", "com.docker.compose.volume=" + suffix, self.i.config["project"] + "_" + suffix))
            self.transfer("restore-volumes", self.volume_command("restore"), input_path=directory / "volumes.tar")
            record["phase"] = "volumes-restored"
            self.i.save()
        if record["phase"] == "volumes-restored":
            self.i.compose("restore-data-start", "up", "-d", "--wait", "postgres", "redis")
            # Bootstrap owns extensions; application tables are restored as the
            # final non-superuser role. Never replay extension/schema ownership.
            self.transfer("restore-toc", self.compose_args("exec", "-T", "postgres", "pg_restore", "--list"),
                          output=self.i.state / "restore-toc.raw", input_path=directory / "database.dump")
            listing = filtered_toc(read_private(self.i.state / "restore-toc.raw"))
            self.transfer("restore-toc-upload", self.compose_args("exec", "-T", "postgres", "sh", "-c", 'umask 077; cat > /tmp/mi-restore.list'), input_bytes=listing.encode())
            self.transfer("restore-database", self.compose_args("exec", "-T", "postgres", "pg_restore", "--exit-on-error", "--clean", "--if-exists", "--no-owner", "--no-acl", "--role=mi_app", "--use-list=/tmp/mi-restore.list", "-U", "postgres", "-d", "mi_platform"), input_path=directory / "database.dump")
            self.i.compose("restore-toc-remove", "exec", "-T", "postgres", "rm", "-f", "/tmp/mi-restore.list")
            record["phase"] = "database-restored"
            self.i.save()
        require(record["phase"] in ("database-restored", "verified"), "Nepoznata restore faza; aplikacija nije pokrenuta.")
        self.verify_restored()
        record["phase"] = "verified"
        self.i.save()
        print("Restore je provjeren poređenjem DB/foto probe; web i worker ostaju u karantinu. Pregledajte restore-inspect prije aktiviranja.")

    def verify_restored(self):
        source = self.i.config["source"]
        self.i.compose("restore-runtime-verify", "run", "--rm", "--no-deps", "app", "bin/rails", "runner", "installation/verify.rb", source["app_sha"], source["engine_sha"], source["lock_sha256"])
        directory = Path(self.i.config["maintenance"]["path"])
        expected = json.loads(read_private(directory / "probe.json"))
        require(self.probe() == expected, "Vraćeni DB/sadržaj/fotografije ne odgovaraju kopiji; worker nije pokrenut.")

    def inspect(self):
        require(self.i.config.get("restore_quarantine"), "Ova instalacija nije u restore karantinu.")
        require(self.i.config["maintenance"]["phase"] == "verified", "Prvo završite restore kroz resume.")
        self.i.daemon()
        self.verify_restored()
        raw = self.i.compose("restore-queue-review", "run", "--rm", "--no-deps", "app", "bin/rails", "runner", "installation/queue_summary.rb", capture=True)
        value = json.loads(raw.splitlines()[-1])
        print(json.dumps(value, ensure_ascii=False))
        print("Karantin je aktivan; pregledajte red i spoljne integracije prije activate-restored --queue-reviewed.")

    def activate(self, reviewed):
        require(reviewed, "Aktiviranje zahtijeva --queue-reviewed nakon pregleda reda i spoljnih integracija.")
        self.inspect()
        self.i.config["restore_quarantine"] = False
        self.i.config["restore_activated_from"] = self.i.config["maintenance"]["manifest_sha256"]
        del self.i.config["maintenance"]
        self.i.save()
        self.i.resume()
