"""Root-owned Run Command entry point. Application updates never manage PostgreSQL."""

import datetime
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path("/opt/neu-zeit")
MAX_ARCHIVE = 100 * 1024**2
MAX_BACKUP = 1024**3
SHA = r"[0-9a-f]{40}"


def write(path, content):
    temporary = path.with_suffix(path.suffix + ".new")
    temporary.write_text(content)
    temporary.chmod(0o600)
    temporary.replace(path)


def run(*args, env=None, output=None):
    # Build and migration output stays in a root-only log, not command payloads.
    with (ROOT / "operation.log").open("ab") as log:
        result = subprocess.run(args, env=env, stdout=output or log, stderr=log)
    if result.returncode:
        raise RuntimeError(
            "Operation failed: " + args[0] + "; inspect /opt/neu-zeit/operation.log"
        )


def compose(kind, *args, slot=None, revision=None):
    env = os.environ.copy()
    command = ["docker", "compose", "-f", str(ROOT / ("compose." + kind + ".yaml"))]
    if slot:
        env.update(REVISION=revision, APP_PORT="4001" if slot == "blue" else "4002")
        command += ["--project-name", "neu_zeit_" + slot]
    run(*command, *args, env=env)


def objects(config):
    import oci

    signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner()
    return oci.object_storage.ObjectStorageClient(
        {"region": config["region"]}, signer=signer
    )


def fetch(config, name, limit):
    response = objects(config).get_object(
        config["namespace"], config["artifacts"], name
    )
    if int(response.headers["content-length"]) > limit:
        raise RuntimeError("Object exceeds deployment size limit")
    return response.data.content


def initialize(config):
    role = config["role"]
    path = ROOT / (role + ".env")
    if not path.exists():
        settings = json.loads(fetch(config, "bootstrap/" + role + ".json", 8192))
        password = settings["database_password"]
        if not re.fullmatch(r"[0-9a-f]{64}", password):
            raise RuntimeError("Invalid initial database password")
        if role == "database":
            write(path, "POSTGRES_PASSWORD=" + password + "\n")
        else:
            secret, hostname = settings["secret_key_base"], settings["hostname"]
            if not re.fullmatch(r"[0-9a-f]{128}", secret) or not re.fullmatch(
                r"[0-9-]+\.sslip\.io", hostname
            ):
                raise RuntimeError("Invalid initial application configuration")
            write(
                path,
                "DATABASE_URL=ecto://postgres:"
                + password
                + "@10.42.0.20/neu_zeit\n"
                + "SECRET_KEY_BASE="
                + secret
                + "\nPHX_HOST="
                + hostname
                + "\n",
            )
            write(ROOT / "hostname", hostname)
    if role == "database":
        if (ROOT / "database-ready").exists() and not (
            ROOT / "database/PG_VERSION"
        ).exists():
            raise RuntimeError(
                "Database data is missing; refusing to initialize an empty replacement"
            )
        (ROOT / "database").mkdir(exist_ok=True)
        compose("database", "up", "-d", "--wait", "--wait-timeout", "180")
        (ROOT / "database-ready").touch()
        run("systemctl", "enable", "--now", "neu-zeit-backup.timer")


def check_database():
    if (
        not (ROOT / "database-ready").exists()
        or not (ROOT / "database/PG_VERSION").exists()
    ):
        raise RuntimeError("Database data is missing; refusing an empty replacement")
    compose(
        "database",
        "exec",
        "-T",
        "database",
        "pg_isready",
        "-U",
        "postgres",
        "-d",
        "neu_zeit",
    )


def caddyfile(hostname, slot, revision):
    port = 4001 if slot == "blue" else 4002
    return f"""{hostname} {{
  handle /__deployment {{
    rewrite * /terms
    reverse_proxy 127.0.0.1:{port} {{
      header_down X-Deployment {revision}
    }}
  }}
  handle {{
    reverse_proxy 127.0.0.1:{port}
  }}
}}
"""


def activate(config_text):
    directory = ROOT / "proxy"
    directory.mkdir(exist_ok=True)
    write(directory / "Caddyfile", config_text)
    compose("proxy", "up", "-d")
    compose(
        "proxy",
        "exec",
        "-T",
        "caddy",
        "caddy",
        "reload",
        "--config",
        "/etc/caddy/Caddyfile",
    )


def https_ready(hostname, revision):
    import time

    for _ in range(60):
        try:
            with urllib.request.urlopen(
                "https://" + hostname + "/__deployment", timeout=5
            ) as response:
                if (
                    response.status == 200
                    and response.headers.get("X-Deployment") == revision
                ):
                    return
        except (OSError, TimeoutError):
            pass
        time.sleep(5)
    raise RuntimeError("HTTPS verification failed")


def unpack(archive, directory):
    with tarfile.open(archive, "r:gz") as source:
        members = source.getmembers()
        if sum(m.size for m in members) > 1024**3:
            raise RuntimeError("Expanded source exceeds 1 GiB")
        for member in members:
            if (
                not (member.isfile() or member.isdir())
                or Path(member.name).is_absolute()
                or ".." in Path(member.name).parts
            ):
                raise RuntimeError("Unsafe path in source archive")
        # Extract only regular files/directories. Ignore archive ownership and special permission bits.
        for member in members:
            target = directory / member.name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with (
                    source.extractfile(member) as incoming,
                    target.open("wb") as output,
                ):
                    shutil.copyfileobj(incoming, output)
                target.chmod(member.mode & 0o777)


def deploy(config, revision, digest):
    if not re.fullmatch(SHA, revision) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise RuntimeError("Expected a commit SHA and archive checksum")
    if not (ROOT / "application.env").exists():
        raise RuntimeError("Initialize the application configuration first")
    current_path = ROOT / "current.json"
    current = json.loads(current_path.read_text()) if current_path.exists() else None
    if current and current["revision"] == revision:
        https_ready((ROOT / "hostname").read_text(), revision)
        return
    slot = "green" if current and current["slot"] == "blue" else "blue"
    hostname = (ROOT / "hostname").read_text()
    # Only the inactive application slot is disposable; no database operations occur here.
    compose("application", "down", "--remove-orphans", slot=slot, revision=revision)
    with tempfile.TemporaryDirectory(dir=ROOT, prefix="build-") as temporary:
        directory = Path(temporary)
        archive = fetch(config, "releases/" + revision + ".tar.gz", MAX_ARCHIVE)
        if hashlib.sha256(archive).hexdigest() != digest:
            raise RuntimeError("Source archive checksum does not match")
        (directory / "source.tar.gz").write_bytes(archive)
        source = directory / "source"
        source.mkdir()
        unpack(directory / "source.tar.gz", source)
        run(
            "docker",
            "build",
            "--target",
            "production",
            "-t",
            "neu_zeit:" + revision,
            str(source),
        )
    try:
        compose("application", "run", "--rm", "migrate", slot=slot, revision=revision)
        compose(
            "application",
            "up",
            "-d",
            "--wait",
            "--wait-timeout",
            "180",
            "application",
            slot=slot,
            revision=revision,
        )
        activate(caddyfile(hostname, slot, revision))
        https_ready(hostname, revision)
    except Exception:
        if current:
            activate(caddyfile(hostname, current["slot"], current["revision"]))
        else:
            compose("proxy", "down")
        compose("application", "down", slot=slot, revision=revision)
        raise
    write(current_path, json.dumps({"slot": slot, "revision": revision}))
    # Keep the previous image for rollback, but release its container's memory.
    if current:
        compose(
            "application", "stop", slot=current["slot"], revision=current["revision"]
        )
    run("docker", "builder", "prune", "--force", "--keep-storage", "2GB")
    # Images older than the current and previous release are removed explicitly.
    result = subprocess.run(
        ["docker", "image", "ls", "neu_zeit", "--format", "{{.Tag}}"],
        capture_output=True,
        text=True,
        check=True,
    )
    keep = {revision, current["revision"] if current else revision}
    for tag in result.stdout.splitlines():
        if re.fullmatch(SHA, tag) and tag not in keep:
            run("docker", "image", "rm", "neu_zeit:" + tag)


def backup(config):
    check_database()
    with tempfile.TemporaryFile() as dump:
        run(
            "docker",
            "compose",
            "-f",
            str(ROOT / "compose.database.yaml"),
            "exec",
            "-T",
            "database",
            "pg_dump",
            "-U",
            "postgres",
            "-d",
            "neu_zeit",
            "-Fc",
            output=dump,
        )
        size = dump.tell()
        if not 0 < size <= MAX_BACKUP:
            raise RuntimeError("Backup exceeds the 1 GiB limit; no object was uploaded")
        dump.seek(0)
        # Seven fixed names put a hard bound on automatic backup storage.
        day = datetime.datetime.now(datetime.UTC).weekday()
        objects(config).put_object(
            config["namespace"],
            config["backups"],
            f"day-{day}.dump",
            dump,
            content_length=size,
        )


def console(config, tool):
    if tool == "psql" and config["role"] == "database":
        command = [
            "docker",
            "compose",
            "-f",
            str(ROOT / "compose.database.yaml"),
            "exec",
            "database",
            "psql",
            "-U",
            "postgres",
            "-d",
            "neu_zeit",
        ]
    elif tool == "iex" and config["role"] == "application":
        current = json.loads((ROOT / "current.json").read_text())
        container = subprocess.run(
            [
                "docker",
                "ps",
                "-q",
                "--filter",
                "label=com.docker.compose.project=neu_zeit_" + current["slot"],
                "--filter",
                "label=com.docker.compose.service=application",
            ],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        if not container or "\n" in container:
            raise RuntimeError("Expected one running application container")
        command = ["docker", "exec", "-it", container, "/app/bin/neu_zeit", "remote"]
    else:
        raise RuntimeError("Unsupported console for this host")
    os.execvp(command[0], command)


def main():
    os.umask(0o077)
    config = json.loads((ROOT / "config.json").read_text())
    if sys.argv[1:2] == ["console"] and len(sys.argv) == 3:
        console(config, sys.argv[2])
        return
    with (ROOT / "operation.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        command, *arguments = sys.argv[1:]
        (ROOT / "operation.log").write_text("")
        if command == "init" and not arguments:
            initialize(config)
        elif command == "check" and not arguments and config["role"] == "database":
            check_database()
        elif (
            command == "deploy"
            and len(arguments) == 2
            and config["role"] == "application"
        ):
            deploy(config, *arguments)
        elif command == "backup" and not arguments and config["role"] == "database":
            backup(config)
        else:
            raise RuntimeError("Unsupported operation for this host")
    print("NeuZeit operation completed")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Never echo SDK errors, subprocess output, or environment values containing secrets.
        print(
            "NeuZeit operation failed ("
            + type(error).__name__
            + "); see the root-only operation log",
            file=sys.stderr,
        )
        sys.exit(1)
