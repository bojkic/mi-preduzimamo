"""Build first; quiesced backup before migration; never roll back a migrated DB."""
import copy
import hashlib
import re
from pathlib import Path
from datetime import datetime, timezone

from mi_installer import require, read_private
from mi_recovery import Recovery, atomic_private, digest


class Upgrade:
    FORMAT = 1

    def __init__(self, installation):
        self.i = installation

    def git(self, name, *args):
        return self.i.run(name, ["git", "-C", str(self.i.root), *args], capture=True)

    def start(self, revision):
        require(not self.i.config.get("upgrade") and not self.i.config.get("maintenance"), "Operacija je već u toku; koristite resume.")
        require(not self.i.config.get("restore_quarantine"), "Prvo završite restore pregled; upgrade nije izlaz iz karantina.")
        require(isinstance(revision, str) and re.fullmatch(r"[0-9a-f]{40}", revision), "Upgrade zahtijeva --revision sa punim lokalno dostupnim app SHA.")
        require(self.i.config.get("stage") == "running" and not self.i.config.get("worker_quiet"), "Prvo završite postojeću instalaciju/stop postupak kroz resume.")
        old = self.i.config["source"]
        require(revision != old["app_sha"], "Ova verzija je već instalirana.")
        self.git("upgrade-ancestry", "merge-base", "--is-ancestor", old["app_sha"], revision)
        module = self.git("upgrade-protocol", "show", revision + ":script/lib/mi_upgrade.py")
        protocol = re.search(r"(?m)^    FORMAT = (\d+)$", module)
        require(protocol and int(protocol[1]) == self.FORMAT, "Cilj ne podržava ovaj nastavak nadogradnje.")
        self.check_data_layout(revision)
        lock = self.git("upgrade-lock", "show", revision + ":Gemfile.lock")
        blocks = [block for block in lock.split("\n\n") if block.startswith("GIT\n") and "    decidim-bih (" in block]
        require(len(blocks) == 1, "Cilj nema jednoznačan engine pin.")
        match = re.search(r"(?m)^  revision: ([0-9a-f]{40})$", blocks[0])
        require(match is not None, "Cilj mora imati puni engine SHA.")
        # git show's captured stdout is stripped by run; hash actual Git bytes.
        lock_bytes = self.git("upgrade-lock-hash", "rev-parse", revision + ":Gemfile.lock")
        target = {"app_sha": revision, "engine_sha": match[1], "lock_sha256": self.lock_digest(revision)}
        require(re.fullmatch(r"[0-9a-f]{40}", lock_bytes), "Neispravan Git lockfile blob.")
        self.i.config["upgrade"] = {"format": self.FORMAT, "phase": "building", "old_source": copy.deepcopy(old),
                                    "old_image_id": self.i.config["image_id"], "old_compose": read_private(self.i.state / "compose.env"),
                                    "target": target, "image_name": self.i.config["project"] + "-app:" + revision}
        self.i.save()
        self.resume()

    def check_data_layout(self, revision):
        old = (self.i.root / "compose.yml").read_text()
        new = self.git("upgrade-data-layout", "show", revision + ":compose.yml")
        versions = []
        for text in (old, new):
            service = re.search(r"(?ms)^  postgres:\n(.*?)(?=^  [a-zA-Z_]|\Z)", text)
            image = re.search(r"(?m)^    image: postgres:(\d+)(?:\.\d+)*-([a-z]+)@sha256:[0-9a-f]{64}$", service[1]) if service else None
            require(image is not None, "Potreban je pregled PostgreSQL image definicije prije nadogradnje.")
            versions.append(image.groups())
            require(all(text.count(value) == 1 for value in ("postgres:/var/lib/postgresql", "storage:/app/storage", "redis:/data")), "Promjena trajnog storage mapiranja zahtijeva zaseban postupak.")
        require(versions[0] == versions[1], "PostgreSQL major/distribucija zahtijevaju zasebnu migraciju; app upgrade nije pokrenut.")
        definitions = [re.search(r"(?ms)^volumes:\n(.*?)(?=^\S|\Z)", text) for text in (old, new)]
        require(all(definitions) and definitions[0][1].strip() == definitions[1][1].strip(), "Promjena definicije trajnih volumena zahtijeva zaseban postupak.")

    def lock_digest(self, revision):
        import subprocess
        result = subprocess.run(["git", "-C", str(self.i.root), "show", revision + ":Gemfile.lock"], capture_output=True, env=self.i.environment)
        require(result.returncode == 0, "Ciljni lockfile nije dostupan.")
        return hashlib.sha256(result.stdout).hexdigest()

    def record(self):
        record = self.i.config.get("upgrade")
        require(isinstance(record, dict) and record.get("format") == self.FORMAT, "Nepoznat upgrade zapis.")
        return record

    def reconcile(self, actual):
        record = self.record()
        require(record["phase"] == "cutover", "Nepoznata Git/config cutover faza.")
        if actual == record["old_source"]:
            return
        require(actual == record["target"], "Checkout ne odgovara starom ili novom upgrade paru; ništa nije prepisano.")
        old = record["old_compose"]
        rows = old.splitlines()
        updated = "\n".join("MI_IMAGE=" + record["image_name"] if row.startswith("MI_IMAGE=") else
                            "MI_APP_SHA=" + actual["app_sha"] if row.startswith("MI_APP_SHA=") else row for row in rows) + "\n"
        current = read_private(self.i.state / "compose.env")
        require(current in (old, updated), "Compose konfiguracija je promijenjena mimo cutover-a.")
        atomic_private(self.i.state / "compose.env", updated)
        self.i.context(source=actual, directory="build-context")
        self.i.config.update(source=copy.deepcopy(actual), image_id=record["image_id"], stage="database-ready")
        self.i.config["files"]["compose.env"] = hashlib.sha256(updated.encode()).hexdigest()
        record["phase"] = "migrating"
        self.i.save()

    def resume(self):
        record = self.record()
        self.i.daemon(for_build=record["phase"] == "building")
        if record["phase"] == "building":
            self.i.context(source=record["target"], directory="upgrade-context")
            target = "demo" if self.i.config["profile"] == "demo" else "runtime"
            self.i.run("upgrade-image-build", self.i.docker_args("build", "--target", target, "--tag", record["image_name"],
                       "--build-arg", "MI_APP_BUILD_REVISION=" + record["target"]["app_sha"], "--build-arg", "MI_RUNTIME_UID=" + str(self.i.config["runtime_uid"]),
                       str(self.i.state / "upgrade-context")))
            image = self.i.run("upgrade-image-identity", self.i.docker_args("image", "inspect", "--format", "{{.Id}}", record["image_name"]), capture=True)
            require(re.fullmatch(r"sha256:[0-9a-f]{64}", image), "Novi image nema puni identitet.")
            record.update(phase="built", image_id=image)
            self.i.save()
        if record["phase"] == "built":
            record.update(phase="snapshot", previous_backup=self.i.config.get("last_backup", {}).get("manifest_sha256"))
            self.i.save()
        if record["phase"] == "snapshot":
            backup = self.i.config.get("last_backup", {})
            completed = self.i.config.get("services_stopped_for_upgrade") and backup.get("source") == record["old_source"] and backup.get("manifest_sha256") != record["previous_backup"]
            if not completed:
                Recovery(self.i).backup(restart=False)
                backup = self.i.config["last_backup"]
            require(backup["source"] == record["old_source"], "Backup nije za postojeći par.")
            directory = Path(backup["path"])
            Recovery(self.i).validate_backup(directory)
            require(digest(directory / "manifest.json") == backup["manifest_sha256"], "Pre-upgrade backup se promijenio.")
            record.update(phase="cutover", backup=copy.deepcopy(backup))
            self.i.save()
        if record["phase"] == "cutover":
            if self.i.source() == record["old_source"]:
                self.git("upgrade-checkout", "checkout", "--detach", record["target"]["app_sha"])
            self.reconcile(self.i.source())
        if record["phase"] == "migrating":
            self.i.compose("upgrade-data-start", "up", "-d", "--wait", "postgres", "redis")
            self.i.compose("upgrade-migrations", "run", "--rm", "--no-deps", "app", "bin/rails", "db:migrate", "data:migrate")
            record["phase"] = "migrated"
            self.i.save()
        require(record["phase"] == "migrated", "Nepoznata upgrade faza; podaci nisu vraćeni unazad.")
        self.i.resume()
        self.i.verify_running()
        self.i.config["last_upgrade"] = {"from": record["old_source"], "to": record["target"], "backup": record["backup"], "at": datetime.now(timezone.utc).isoformat()}
        del self.i.config["upgrade"]
        self.i.config.pop("services_stopped_for_upgrade", None)
        self.i.save()
        print("Nadogradnja je završena. Backup starog para je sačuvan; spoljne dostave nisu ovim testirane.")

    def abort(self):
        record = self.record()
        require(record["phase"] in ("building", "built", "snapshot"), "Cutover/migracije su započeti; nema automatskog rollback-a. Koristite pregledan forward repair ili restore starog para u novom cilju.")
        require(self.i.source() == record["old_source"], "Izvor nije stari par; odbijeno bez Git prepisivanja.")
        maintenance = self.i.config.get("maintenance")
        if maintenance:
            require(maintenance["kind"] == "backup", "Druga maintenance operacija je u toku.")
            self.i.config.setdefault("abandoned_snapshots", []).append(copy.deepcopy(maintenance))
            del self.i.config["maintenance"]
        del self.i.config["upgrade"]
        self.i.config.pop("services_stopped_for_upgrade", None)
        self.i.save()
        self.i.resume()
        print("Nadogradnja je otkazana prije cutover-a; stari par je pokrenut, a kopije nisu brisane.")
