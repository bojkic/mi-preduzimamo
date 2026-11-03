"""One installation, one explicit Docker endpoint and private state directory.

All Docker operations use the same recorded project/profile/endpoint. Shell
configuration is never sourced, eval'd or allowed to override Compose inputs.
"""
import argparse
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import re
import secrets
import shutil
import socket
import stat
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone


class InstallError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise InstallError(message)


def private_file(path, content, exclusive=False):
    flags = os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW
    flags |= os.O_EXCL if exclusive else os.O_TRUNC
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, "w") as stream:
        os.fchmod(stream.fileno(), 0o600)
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())


def read_private(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as stream:
        meta = os.fstat(stream.fileno())
        require(stat.S_ISREG(meta.st_mode) and meta.st_uid == os.getuid(), "Pogrešan vlasnik/tip privatnog fajla.")
        require(meta.st_mode & 0o077 == 0, "Privatni fajl mora imati prava 0600.")
        return stream.read()


class Installation:
    FORMAT = 1
    COMMANDS = ("install", "resume", "check", "verify", "start", "stop", "restart", "status", "admin", "demo-system", "demo-content", "configure", "backup", "restore", "restore-inspect", "activate-restored", "upgrade", "upgrade-abort", "demo-probe", "demo-probe-status", "recreate")
    CONFIGURABLE = {
        "DECIDIM_APPLICATION_NAME", "DECIDIM_MAILER_SENDER", "SMTP_ADDRESS", "SMTP_PORT",
        "SMTP_DOMAIN", "SMTP_STARTTLS_AUTO", "SMTP_OPENSSL_VERIFY_MODE", "SMTP_AUTHENTICATION",
        "SMTP_USERNAME", "SMTP_PASSWORD"
    }
    FORBIDDEN = {"DATABASE_URL", "POSTGRES_PASSWORD", "DATABASE_PASSWORD", "SECRET_KEY_BASE", "DECIDIM_API_JWT_SECRET", "WEB_PORT", "MAIL_PORT"}

    def __init__(self, root):
        self.root = Path(root).resolve()
        self.state = self.root / ".mi-install"
        self.config = None
        self.docker = shutil.which("docker")
        self.environment = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": os.environ.get("HOME", "/tmp"), "LANG": "C.UTF-8"}

    def reject_conflicts(self):
        conflicts = sorted(k for k in os.environ if os.environ[k] and (k.startswith(("COMPOSE_", "DOCKER_")) or k in self.FORBIDDEN))
        require(not conflicts, "Konfliktne naslijeđene promjenljive: " + ", ".join(conflicts) + ". Koristite opcije instalera; ništa nije promijenjeno.")

    def lock(self):
        fd = os.open(self.root / ".mi-install.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        require(os.fstat(fd).st_uid == os.getuid(), "Pogrešan vlasnik lock fajla.")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            raise InstallError("Druga komanda ove instalacije je u toku.") from None
        return fd

    def source(self):
        def git(*args):
            proc = subprocess.run(["git", "-C", str(self.root), *args], capture_output=True, text=True, env=self.environment)
            require(proc.returncode == 0, "Nije moguće provjeriti Git izvor.")
            return proc.stdout.strip()
        require(not git("status", "--porcelain", "--untracked-files=normal"), "Izvor mora biti commitovan i čist; sačuvajte lokalne izmjene u svojoj grani prije build-a.")
        sha = git("rev-parse", "HEAD")
        require(re.fullmatch(r"[0-9a-f]{40}", sha), "Neispravan app commit.")
        lock = (self.root / "Gemfile.lock").read_text()
        blocks = [b for b in lock.split("\n\n") if b.startswith("GIT\n") and "    decidim-bih (" in b]
        require(len(blocks) == 1, "Nije pronađen jednoznačan engine pin.")
        match = re.search(r"(?m)^  revision: ([0-9a-f]{40})$", blocks[0])
        require(match is not None, "Engine mora imati puni Git SHA.")
        return {"app_sha": sha, "engine_sha": match[1], "lock_sha256": hashlib.sha256(lock.encode()).hexdigest()}

    def docker_args(self, *args):
        require(self.docker is not None, "Instalirajte Docker Engine/CLI i Compose v2 prema vodiču.")
        return [self.docker, "--config", str(self.state / "docker-client"), "--host", self.config["docker_host"], *args]

    def run(self, name, args, capture=False):
        proc = subprocess.run(args, cwd=self.root, env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        # Logs are private and never printed by default: Rails errors can include
        # configuration. The summary exposes operation and exit code only.
        logs = self.state / "logs"
        logs.mkdir(mode=0o700, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%f")
        private_file(logs / (stamp + "-" + name + ".log"), (proc.stdout + proc.stderr).decode(errors="replace"), exclusive=True)
        require(proc.returncode == 0, f"Korak {name} nije uspio (exit {proc.returncode}); privatni log je u .mi-install/logs. Tajne i podaci su sačuvani; koristite resume.")
        return proc.stdout.decode().strip() if capture else None

    def compose_args(self, *args):
        command = self.docker_args("compose", "--project-directory", str(self.root), "--env-file", str(self.state / "compose.env"), "--project-name", self.config["project"], "-f", str(self.root / "compose.yml"), "-f", str(self.root / "installation" / ("compose." + self.config["profile"] + ".yml")))
        if self.config.get("restore_quarantine"):
            command += ["-f", str(self.root / "installation/compose.restore.yml")]
        return command + list(args)

    def compose(self, name, *args, capture=False):
        return self.run(name, self.compose_args(*args), capture=capture)

    def save(self):
        temp = self.state / "config.next"
        private_file(temp, json.dumps(self.config, indent=2) + "\n")
        os.replace(temp, self.state / "config.json")
        fd = os.open(self.state, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    def load(self):
        require(self.state.is_dir() and not self.state.is_symlink(), "Instalacija ne postoji; prvo koristite install.")
        require(self.state.stat().st_uid == os.getuid() and self.state.stat().st_mode & 0o077 == 0, "Privatni direktorijum mora pripadati operateru i imati prava 0700.")
        self.config = json.loads(read_private(self.state / ("config.json" if (self.state / "config.json").exists() else "config.next")))
        require(self.config["format"] == self.FORMAT and self.config["root"] == str(self.root), "Konfiguracija pripada drugom formatu ili checkout-u.")
        require(re.fullmatch(r"mi-[0-9a-f]{16}", self.config["project"]), "Neispravan project identitet.")
        require(self.config["profile"] in ("demo", "production"), "Nepoznat profil.")
        actual_source = self.source()
        if self.config.get("upgrade", {}).get("phase") == "cutover":
            from mi_upgrade import Upgrade
            Upgrade(self).reconcile(actual_source)
        require(self.config["source"] == actual_source, "Izvor je promijenjen; ne koristite new install nad postojećim podacima. Primijenite dokumentovan postupak nadogradnje.")
        if self.config.get("maintenance", {}).get("kind") == "restore" and self.config["maintenance"]["phase"] == "prepared":
            from mi_recovery import Recovery
            Recovery(self).restore_configuration()
        self.reconcile_configuration()
        for name, digest in self.config["files"].items():
            require(name in {"app.env", "db.env", "compose.env"}, "Nepoznat privatni fajl.")
            require(hashlib.sha256(read_private(self.state / name).encode()).hexdigest() == digest, "Konfiguracija je promijenjena mimo instalera; pregledajte dokumentovan postupak prije nastavka.")

    def reconcile_configuration(self):
        pending = self.config.get("configuration_pending")
        if not pending:
            return
        require(set(pending) == {"previous", "next"}, "Nepoznat zapis izmjene konfiguracije.")
        current = hashlib.sha256(read_private(self.state / "app.env").encode()).hexdigest()
        require(current in (pending["previous"], pending["next"]), "Prekinuta konfiguracija ima neočekivan sadržaj; odbijeno bez prepisivanja.")
        if current == pending["previous"]:
            staged = read_private(self.state / "app.env.next")
            require(hashlib.sha256(staged.encode()).hexdigest() == pending["next"], "Pripremljena konfiguracija nije važeća.")
            os.replace(self.state / "app.env.next", self.state / "app.env")
        self.config["files"]["app.env"] = pending["next"]
        del self.config["configuration_pending"]
        self.save()

    def configure(self, input_path):
        require(self.config["profile"] == "production", "Demo SMTP i profil su fiksni; produkcionu konfiguraciju unesite u zasebnu instalaciju.")
        require(input_path is not None, "Navedite --env-file sa privatnim KEY=VALUE fajlom.")
        incoming = {}
        for line in read_private(Path(input_path)).splitlines():
            if not line.strip() or line.startswith("#"):
                continue
            key, separator, value = line.partition("=")
            require(separator and key in self.CONFIGURABLE, "Nepoznat ili zaštićen konfiguracioni ključ; ništa nije promijenjeno.")
            require(key not in incoming and not any(c in value for c in ("\x00", "\r", "\n")), "Duplikat ili neispravna konfiguraciona vrijednost.")
            incoming[key] = value
        require(bool(incoming), "Nema konfiguracionih vrijednosti za unos.")
        if "SMTP_PORT" in incoming:
            require(incoming["SMTP_PORT"].isdigit() and 1 <= int(incoming["SMTP_PORT"]) <= 65535, "Neispravan SMTP port.")
        if "SMTP_STARTTLS_AUTO" in incoming:
            require(incoming["SMTP_STARTTLS_AUTO"] in ("true", "false"), "SMTP_STARTTLS_AUTO mora biti true/false.")
        current = read_private(self.state / "app.env")
        rows = dict(line.split("=", 1) for line in current.splitlines())
        rows.update(incoming)
        updated = "".join(key + "=" + value + "\n" for key, value in rows.items())
        if updated == current:
            print("Konfiguracija je već usklađena; tajne nisu promijenjene.")
            return
        private_file(self.state / "app.env.next", updated)
        self.config["configuration_pending"] = {"previous": self.config["files"]["app.env"], "next": hashlib.sha256(updated.encode()).hexdigest()}
        self.save()
        self.reconcile_configuration()
        print("Konfiguracija je sačuvana bez promjene DB/Rails/JWT tajni. Primijenite restart kada ste spremni; dostava nije testirana.")

    def daemon(self, initial=False, for_build=False):
        version = self.run("compose-version", self.docker_args("compose", "version", "--short"), capture=True)
        match = re.match(r"v?(\d+)\.(\d+)\.(\d+)", version)
        require(match and tuple(map(int, match.groups())) >= (2, 30, 0), "Potreban je Docker Compose 2.30+ zbog literalnog env_file formata.")
        identity = self.run("docker-identity", self.docker_args("info", "--format", "{{.ID}}"), capture=True)
        require(bool(identity), "Docker daemon nema identitet.")
        if for_build:
            memory = self.run("docker-memory", self.docker_args("info", "--format", "{{.MemTotal}}"), capture=True)
            require(memory.isdigit() and int(memory) >= 4 * 1024**3, "Docker build putanja zahtijeva najmanje 4 GiB dodijeljenog RAM-a; ne mijenjam globalna podešavanja.")
        if initial:
            self.config["daemon_id"] = identity
            self.save()
        else:
            require(identity == self.config["daemon_id"], "Docker endpoint sada vodi na drugi daemon; odbijeno prije rada nad servisima.")
            if self.config.get("resources_cleared"):
                self.resources()

    def port_available(self, port):
        require(1024 <= port <= 65535, "Port mora biti između 1024 i 65535.")
        with socket.socket() as sock:
            try:
                sock.bind(("127.0.0.1", port))
            except OSError:
                raise InstallError(f"Loopback port {port} je zauzet; ništa nije prepisano.") from None

    def prepare(self, args):
        args.web_port = args.web_port if args.web_port is not None else 3100
        args.mail_port = args.mail_port if args.mail_port is not None else 8125
        args.docker_host = args.docker_host or "unix:///var/run/docker.sock"
        require(platform.system() == "Linux" and platform.machine() == "x86_64", "Ova putanja podržava Linux x86_64, uključujući WSL2.")
        require(not self.state.exists() and not self.state.is_symlink(), "Postoji .mi-install; ne prepisujem konfiguraciju ili podatke. Koristite resume/check.")
        require(args.profile is not None, "Izaberite --profile demo ili production.")
        require(args.web_port != args.mail_port, "Web i mail port moraju biti različiti.")
        self.port_available(args.web_port)
        if args.profile == "demo":
            self.port_available(args.mail_port)
        require(shutil.disk_usage(self.root).free >= 15 * 1024**3, "Za novu izgradnju obezbijedite najmanje 15 GiB slobodnog prostora; ništa se automatski ne briše.")
        if args.profile == "production":
            require(args.domain and re.fullmatch(r"(?=.{1,253}$)[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,63}", args.domain), "Produkcioni profil zahtijeva --domain sa vlastitim domenom.")
        require(args.docker_host.startswith("unix:///") and "\n" not in args.docker_host, "Podržan je izričit lokalni Unix Docker socket; udaljeni nezaštićeni endpoint je odbijen.")
        require(not args.capture_phone or args.profile == "demo", "Simulirani telefon dozvoljen je samo u demo profilu.")
        source = self.source()
        self.state.mkdir(mode=0o700)
        (self.state / "docker-client").mkdir(mode=0o700)
        (self.state / "private").mkdir(mode=0o700)
        project = "mi-" + secrets.token_hex(8)
        domain = args.domain if args.profile == "production" else "127.0.0.1"
        self.config = {"format": self.FORMAT, "root": str(self.root), "project": project, "profile": args.profile, "docker_host": args.docker_host, "source": source, "stage": "preparing", "files": {}, "ports": {"web": args.web_port, "mail": args.mail_port}, "domain": domain, "runtime_uid": os.getuid() if os.getuid() >= 1000 else 1000, "capture_phone": args.capture_phone}
        if os.getuid() == 0:
            os.chown(self.state / "private", self.config["runtime_uid"], self.config["runtime_uid"])
        self.save()
        self.finish_configuration(args.web_port, args.mail_port, domain)
        self.daemon(initial=True, for_build=True)
        self.resources(initial=True)

    def resources(self, initial=False):
        rows = self.run("resource-identity", self.docker_args("volume", "ls", "--filter", "name=" + self.config["project"] + "_", "--format", '{{.Name}}\t{{.Label "com.docker.compose.project"}}'), capture=True)
        for row in rows.splitlines():
            name, _, project = row.partition("\t")
            if name in {self.config["project"] + "_" + suffix for suffix in ("postgres", "redis", "storage", "mail")}:
                require(not initial and project == self.config["project"], "Postoji tuđi/neočekivan volumen; ništa nije prepisano.")
        if initial:
            self.config["resources_cleared"] = True
            self.save()


    def finish_configuration(self, web_port=None, mail_port=None, domain=None):
        project = self.config["project"]
        if "ports" not in self.config:
            self.config.update(ports={"web": web_port, "mail": mail_port}, domain=domain)
            self.save()
        web_port, mail_port, domain = self.config["ports"]["web"], self.config["ports"]["mail"], self.config["domain"]
        profile, source = self.config["profile"], self.config["source"]
        app_password = secrets.token_hex(32)
        values = {
          "compose.env": f"MI_IMAGE={project}-app:{source['app_sha'][:12]}\nMI_APP_SHA={source['app_sha']}\nMI_RUNTIME_UID={self.config['runtime_uid']}\nMI_PROFILE={profile}\nMI_INSTALL_ID={project}\nMI_WEB_PORT={web_port}\nMI_MAIL_PORT={mail_port}\nMI_DOMAIN={domain}\n",
          "app.env": "RAILS_ENV=production\nRACK_ENV=production\nSECRET_KEY_BASE=" + secrets.token_hex(64) + "\nDECIDIM_API_JWT_SECRET=" + secrets.token_hex(64) + "\nDATABASE_HOST=postgres\nDATABASE_USERNAME=mi_app\nDATABASE_PASSWORD=" + app_password + "\nDATABASE_URL=postgresql://mi_app:" + app_password + "@postgres/mi_platform\nQUEUE_ADAPTER=sidekiq\nREDIS_URL=redis://redis:6379/0\nRAILS_ALLOWED_HOSTS=" + domain + "\nMI_INSTALL_ID=" + project + "\nMI_INSTALL_PROFILE=" + profile + "\nMI_DEMO_PHONE_CAPTURE=" + ("true" if self.config.get("capture_phone") else "false") + "\nMI_RUNTIME_STATE_DIR=/app/tmp\nRAILS_LOG_TO_STDOUT=true\n",
        }
        if (self.state / "app.env").exists():
            values["app.env"] = read_private(self.state / "app.env")
        app_password = next(line.split("=", 1)[1] for line in values["app.env"].splitlines() if line.startswith("DATABASE_PASSWORD="))
        values["db.env"] = "POSTGRES_DB=mi_platform\nPOSTGRES_USER=postgres\nPOSTGRES_PASSWORD=" + secrets.token_hex(32) + "\nMI_APP_DATABASE_PASSWORD=" + app_password + "\n"
        for name, value in values.items():
            path = self.state / name
            if path.exists():
                value = read_private(path)
            else:
                private_file(path, value, exclusive=True)
            self.config["files"][name] = hashlib.sha256(value.encode()).hexdigest()
            self.save()
        self.config["stage"] = "prepared"
        self.save()


    def context(self, source=None, directory="build-context"):
        require(directory in ("build-context", "upgrade-context"), "Neispravno ime build direktorijuma.")
        source = source or self.config["source"]
        target = self.state / directory
        if target.exists():
            require(target.is_dir() and not target.is_symlink() and not os.path.ismount(target), "Neispravan build context.")
            require((target / ".mi-build-owned").read_text() == self.config["project"], "Nepoznat build context; ne brišem sadržaj.")
            shutil.rmtree(target)
        target.mkdir(mode=0o700)
        (target / ".mi-build-owned").write_text(self.config["project"])
        archive = subprocess.run(["git", "-C", str(self.root), "archive", source["app_sha"]], capture_output=True, env=self.environment)
        require(archive.returncode == 0, "Git archive nije uspio.")
        with tarfile.open(fileobj=io.BytesIO(archive.stdout)) as tar:
            for item in tar.getmembers():
                require(not item.issym() and not item.islnk() and not item.name.startswith("/") and ".." not in Path(item.name).parts, "Build dozvoljava samo regularne Git fajlove/direktorijume.")
            tar.extractall(target, filter="data")

    def resume(self, force_recreate=False):
        if self.config["stage"] == "preparing":
            self.finish_configuration()
        self.daemon(initial="daemon_id" not in self.config, for_build=self.config["stage"] in ("prepared", "building"))
        self.resources(initial=not self.config.get("resources_cleared", False))
        self.compose("compose-check", "config", "--quiet")
        if self.config["stage"] in ("prepared", "building"):
            self.config["stage"] = "building"
            self.save()
            self.context()
            self.compose("build", "build", "--build-arg", "MI_ENGINE_BUILD_REVISION=" + self.config["source"]["engine_sha"],
                         "--build-arg", "MI_LOCK_BUILD_SHA256=" + self.config["source"]["lock_sha256"], "app")
            image = self.config["project"] + "-app:" + self.config["source"]["app_sha"][:12]
            identity = self.run("built-image", self.docker_args("image", "inspect", "--format", "{{.Id}}", image), capture=True)
            require(re.fullmatch(r"sha256:[0-9a-f]{64}", identity), "Image build nije dao puni identitet.")
            self.config["image_id"] = identity
            self.config["stage"] = "built"
            self.save()
        self.verify_selected_image()
        if self.config["stage"] == "built":
            self.compose("data-services", "up", "-d", "--wait", "--wait-timeout", "180", "postgres", "redis")
            self.compose("database-prepare", "run", "--rm", "app", "bin/rails", "db:prepare")
            self.compose("database-identity", "run", "--rm", "app", "bin/rails", "runner", "installation/initialize.rb")
            self.config["stage"] = "database-ready"
            self.save()
        require(self.config["stage"] in ("database-ready", "running"), "Nepoznato djelimično stanje; podaci nisu promijenjeni.")
        if self.config.get("worker_quiet"):
            if self.worker_running():
                self.compose("worker-quiet", "kill", "--signal", "TSTP", "worker")
                self.compose("worker-drain", "exec", "-T", "worker", "bundle", "exec", "ruby", "installation/drain.rb")
                self.compose("worker-stop", "stop", "--timeout", "90", "worker")
            self.config["worker_quiet"] = False
            self.save()
        options = ["up", "-d", "--wait", "--wait-timeout", "180", "--no-build"]
        if force_recreate:
            options.append("--force-recreate")
        self.compose("services-start", *options)
        self.verify_running()
        self.config["stage"] = "running"
        self.save()
        print("Servisi su pokrenuti. Provjerite ./script/mi_install verify; zatim kreirajte administratora i organizaciju prema uputstvu.")

    def verify_selected_image(self):
        rows = dict(line.split("=", 1) for line in read_private(self.state / "compose.env").splitlines())
        name = rows.get("MI_IMAGE", "")
        require(name.startswith(self.config["project"] + "-app:") and name.split(":")[-1] in (self.config["source"]["app_sha"], self.config["source"]["app_sha"][:12]), "Image tag ne odgovara ovom projektu i izvoru.")
        actual = self.run("selected-image", self.docker_args("image", "inspect", "--format", "{{.Id}}", name), capture=True)
        require(actual == self.config.get("image_id"), "Lokalni image tag ne odgovara zabilježenom image-u; odbijeno prije pokretanja.")

    def verify_running(self):
        self.verify_selected_image()
        containers = self.compose("runtime-containers", "ps", "--quiet", "app", "worker", capture=True).splitlines()
        require(len(containers) == 2 and all(re.fullmatch(r"[0-9a-f]{12,64}", value) for value in containers), "Web i worker moraju biti pokrenuti.")
        for container in containers:
            image = self.run("runtime-image", self.docker_args("inspect", "--format", "{{.Image}}", container), capture=True)
            require(image == self.config.get("image_id"), "Pokrenuti image ne odgovara izgrađenom kandidatu.")
        source = self.config["source"]
        self.compose("runtime-verify", "exec", "-T", "app", "bin/rails", "runner", "installation/verify.rb", source["app_sha"], source["engine_sha"], source["lock_sha256"])
        self.verify_http()

    def verify_http(self, timeout=30):
        # Probe the operator-facing demo gateway, not only the app container.
        # Production probes its loopback backend; public TLS is a separate check.
        port = self.config["ports"]["web"]
        require(isinstance(port, int) and 1024 <= port <= 65535, "Neispravan HTTP port instalacije.")
        headers = {"Host": self.config["domain"]}
        if self.config["profile"] == "production":
            headers["X-Forwarded-Proto"] = "https"
        request = urllib.request.Request(f"http://127.0.0.1:{port}/up", headers=headers)
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                return None

        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        deadline = time.monotonic() + timeout
        while True:
            try:
                with opener.open(request, timeout=2) as response:
                    if response.status == 200:
                        return
            except urllib.error.HTTPError as error:
                error.close()
            except (OSError, urllib.error.URLError):
                pass
            require(time.monotonic() < deadline, "HTTP putanja instalacije nije spremna; image/worker provjera sama nije dokaz dostupnog gateway-a. Stanje je sačuvano; koristite resume.")
            time.sleep(1)

    def worker_running(self):
        return bool(self.compose("worker-running", "ps", "--status", "running", "--quiet", "worker", capture=True))

    def stop_services(self):
        if self.worker_running():
            self.config["worker_quiet"] = True
            self.save()
            self.compose("worker-quiet", "kill", "--signal", "TSTP", "worker")
            self.compose("worker-drain", "exec", "-T", "worker", "bundle", "exec", "ruby", "installation/drain.rb")
        self.compose("stop", "stop", "--timeout", "90")
        self.config["worker_quiet"] = False
        self.save()

    def execute(self, args):
        from mi_recovery import Recovery
        from mi_upgrade import Upgrade
        self.reject_conflicts()
        lock = self.lock()
        try:
            require(args.command == "upgrade" or getattr(args, "revision", None) is None, "--revision se koristi samo uz upgrade.")
            require(args.command == "backup" or getattr(args, "output", None) is None, "--output se koristi samo uz backup.")
            require(args.command == "restore" or getattr(args, "backup", None) is None, "--backup se koristi samo uz restore.")
            require(args.command == "activate-restored" or not getattr(args, "queue_reviewed", False), "--queue-reviewed se koristi samo pri aktiviranju restore-a.")
            if args.command == "restore":
                require(not args.capture_phone and args.profile is None and args.domain is None and getattr(args, "env_file", None) is None, "Restore čuva izvorni profil i tajne; ne prihvata install/configure zastavice.")
                Recovery(self).restore(args)
                return
            if args.command == "install":
                require(getattr(args, "env_file", None) is None, "Konfiguraciju unesite zasebnom configure komandom.")
                self.prepare(args)
                self.resume()
                return
            require(not args.capture_phone, "Capture zastavica se bira samo pri novoj demo instalaciji.")
            require(all(getattr(args, n) is None for n in ("profile", "domain", "web_port", "mail_port", "docker_host")), "Promjena endpoint-a/profila/portova nije dozvoljena kroz operativnu komandu.")
            self.load()
            require(args.command == "configure" or getattr(args, "env_file", None) is None, "--env-file se koristi samo uz configure.")
            require(not self.config.get("upgrade") or args.command in ("resume", "check", "status", "upgrade-abort"), "Upgrade je u toku; koristite resume/check/status ili upgrade-abort prije cutover-a.")
            maintenance = self.config.get("maintenance", {})
            require(not maintenance or args.command in ("resume", "backup", "check", "status", "restore-inspect", "activate-restored", "upgrade-abort"), "Maintenance je u toku; koristite resume/check/status.")
            require(not self.config.get("restore_quarantine") or args.command in ("resume", "check", "status", "restore-inspect", "activate-restored"), "Restore je u karantinu; koristite restore-inspect, zatim activate-restored tek poslije pregleda.")
            if args.command == "upgrade":
                Upgrade(self).start(getattr(args, "revision", None))
            elif args.command == "upgrade-abort":
                Upgrade(self).abort()
            elif args.command == "backup":
                Recovery(self).backup(getattr(args, "output", None))
            elif args.command == "restore-inspect":
                Recovery(self).inspect()
            elif args.command == "activate-restored":
                Recovery(self).activate(getattr(args, "queue_reviewed", False))
            elif args.command == "configure":
                self.configure(args.env_file)
            elif args.command == "resume":
                if self.config.get("upgrade"):
                    Upgrade(self).resume()
                elif maintenance.get("kind") == "backup":
                    Recovery(self).backup()
                elif maintenance.get("kind") == "restore":
                    Recovery(self).resume_restore()
                else:
                    self.resume()
            elif args.command == "check":
                self.daemon()
                self.compose("compose-check", "config", "--quiet")
                print("Konfiguracija, izvor, projekat i Docker endpoint odgovaraju zapisu; tajne nisu ispisane.")
            elif args.command == "verify":
                self.daemon()
                self.verify_running()
                print("Runtime provjera prošla; ovo nije potvrda spoljne dostave ili VPS prihvatanja.")
            elif args.command == "stop":
                self.daemon()
                self.stop_services()
            elif args.command in ("start", "restart", "recreate"):
                if args.command in ("restart", "recreate"):
                    self.daemon()
                    self.stop_services()
                self.resume(force_recreate=args.command == "recreate")
            elif args.command == "status":
                self.daemon()
                print(self.compose("status", "ps", capture=True))
            elif args.command in ("demo-probe", "demo-probe-status"):
                require(self.config["profile"] == "demo", "Worker probe je dozvoljen samo u demo profilu.")
                self.daemon()
                if args.command == "demo-probe":
                    self.config["worker_probe_id"] = secrets.token_hex(16)
                    self.save()
                identity = self.config.get("worker_probe_id")
                require(identity and re.fullmatch(r"[0-9a-f]{32}", identity), "Prvo pokrenite demo-probe.")
                action = "enqueue" if args.command == "demo-probe" else "status"
                value = self.compose("demo-worker-probe", "exec", "-T", "app", "bin/rails", "runner", "installation/demo/drain_probe.rb", action, identity, capture=True)
                print(json.dumps(json.loads(value.splitlines()[-1]), ensure_ascii=False))
            elif args.command in ("demo-system", "demo-content"):
                self.daemon()
                require(self.config["profile"] == "demo", "Demo provisioning is refused outside the demo profile.")
                script = "installation/demo/setup_system.rb" if args.command == "demo-system" else "installation/demo/setup_content.rb"
                self.compose("demo-provision", "exec", "-T", "app", "bin/rails", "runner", script)
                print("Demo pristupni podaci su u .mi-install/private/credentials.json; otvorite ih privatno u editoru, ne šaljite u izvještaj.")
            elif args.command == "admin":
                self.daemon()
                require(self.config["profile"] == "production", "Demo pristup se priprema zasebnim demo alatom iz vodiča.")
                subprocess.run(self.docker_args("compose", "--project-directory", str(self.root), "--env-file", str(self.state / "compose.env"), "--project-name", self.config["project"], "-f", str(self.root / "compose.yml"), "-f", str(self.root / "installation/compose.production.yml"), "exec", "app", "bin/rails", "decidim_system:create_admin"), env=self.environment, check=True)
        finally:
            os.close(lock)


def main(argv=None):
    parser = argparse.ArgumentParser(description="MI preduzimamo — izdvojena instalacija; postojeći podaci se ne brišu.")
    parser.add_argument("command", choices=Installation.COMMANDS)
    parser.add_argument("--profile", choices=("demo", "production"))
    parser.add_argument("--domain")
    parser.add_argument("--capture-phone", action="store_true", help="Samo demo: simulacija za +15555550101 u lokalnom Mailpit-u")
    parser.add_argument("--web-port", type=int)
    parser.add_argument("--mail-port", type=int)
    parser.add_argument("--docker-host")
    parser.add_argument("--revision", help="upgrade: puni SHA potomka trenutnog app commita; prethodno git fetch")
    parser.add_argument("--output", type=Path, help="backup: novo odredište ispod privatnog direktorijuma")
    parser.add_argument("--backup", type=Path, help="restore: postojeći privatni backup direktorijum")
    parser.add_argument("--queue-reviewed", action="store_true", help="activate-restored: operater je pregledao red i spoljne integracije")
    parser.add_argument("--env-file", help="configure: privatni literalni KEY=VALUE fajl; ne izvršava se kao shell")
    args = parser.parse_args(argv)
    try:
        Installation(Path(__file__).resolve().parents[2]).execute(args)
    except (InstallError, OSError, ValueError, tarfile.TarError, subprocess.CalledProcessError) as error:
        print("mi_install: " + (str(error) if isinstance(error, InstallError) else "Sistemska greška; vrijednosti konfiguracije nisu ispisane."), file=sys.stderr)
        return 1
    return 0
