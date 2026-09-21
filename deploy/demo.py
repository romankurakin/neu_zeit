"""Replace application hosts without replacing the database host."""
import base64
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent
NAME = "neu-zeit-demo"
APP_TAG = NAME + "-application"
DB_TAG = NAME + "-database"


def do(*args):
    result = subprocess.run(["doctl", *map(str, args), "--output", "json"],
                            capture_output=True, text=True)
    if result.returncode:
        # Do not print command arguments: a future command may contain secrets.
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "DigitalOcean command failed")
    return json.loads(result.stdout) if result.stdout.strip() else None


def one(items, description):
    if len(items) > 1:
        raise RuntimeError("Multiple " + description + "; resolve the duplicate first")
    return items[0] if items else None


def first(result):
    return result[0] if isinstance(result, list) else result


def address(droplet, kind):
    return next(n["ip_address"] for n in droplet["networks"]["v4"] if n["type"] == kind)


def report(message):
    print(message, flush=True)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write(message + "\n")


def wait_until(check, seconds=900, description="deployment readiness"):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(10)
    raise RuntimeError("Timed out waiting for " + description)


def ready(url, revision):
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            return response.status == 200 and response.headers.get("X-Deployment") == revision
    except (urllib.error.URLError, TimeoutError, OSError):
        return False


def assign(ip, droplet_id):
    action = first(do("compute", "reserved-ip-action", "assign", ip, droplet_id))
    result = first(do("compute", "action", "wait", action["id"]))
    if result["status"] != "completed":
        raise RuntimeError("Reserved IP assignment failed")


def release_ip(ip):
    def release():
        try:
            do("compute", "reserved-ip", "delete", ip, "--force")
        except RuntimeError as error:
            # DigitalOcean can still be finishing an unassignment after its action completes.
            if "422" not in str(error):
                raise

    release()

    def released():
        if not any(r["ip"] == ip for r in do("compute", "reserved-ip", "list")):
            return True
        release()
        return False

    wait_until(released, 300, description="reserved IP release")


def create_host(name, role, region, vpc, size, values):
    script = ROOT / ("bootstrap-database.sh" if role == DB_TAG else "bootstrap-application.sh")
    content = "#!/bin/bash\n" + "\n".join(k + "=" + shlex.quote(v) for k, v in values.items())
    content += "\n" + script.read_text()
    with tempfile.NamedTemporaryFile(mode="w") as boot:
        boot.write(content)
        boot.flush()
        args = ["compute", "droplet", "create", name, "--image", "ubuntu-24-04-x64",
                "--region", region, "--vpc-uuid", vpc, "--size", size,
                "--tag-names", NAME + "," + role, "--user-data-file", boot.name,
                "--enable-monitoring", "--wait"]
        created = first(do(*args))
    return first(do("compute", "droplet", "get", created["id"]))


def delete_application(droplet):
    tags = droplet.get("tags", [])
    if NAME not in tags or APP_TAG not in tags or DB_TAG in tags:
        raise RuntimeError("Refusing to delete a host that is not an application host")
    # Retained snapshots must remain discoverable after their source host is gone.
    for snapshot in do("compute", "snapshot", "list"):
        if str(snapshot["resource_id"]) == str(droplet["id"]):
            do("compute", "tag", "apply", NAME, "--resource", "do:image:" + str(snapshot["id"]))
    do("compute", "droplet", "delete", droplet["id"], "--force")


def deploy(ip, reserved, droplets):
    if not reserved:
        raise RuntimeError("Reserve an IPv4 and set DEMO_RESERVED_IP before deployment")
    legacy = [d for d in droplets if d["name"] == NAME]
    if legacy:
        raise RuntimeError("The existing single-server installation must be migrated first. "
                           "Its server, database and address have not been changed.")
    revision = os.environ.get("REVISION", "")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise RuntimeError("Deploy requires a resolved full commit SHA")
    password = os.environ.get("DATABASE_PASSWORD", "")
    secret = os.environ.get("SECRET_KEY_BASE", "")
    if not re.fullmatch(r"[0-9a-f]{64}", password) or len(secret) < 64:
        raise RuntimeError("Set stable DEMO_DATABASE_PASSWORD (64 hex characters) and DEMO_SECRET_KEY_BASE secrets")
    repository = os.environ.get("REPOSITORY_URL", "")
    if not re.fullmatch(r"https://[A-Za-z0-9./_-]+\.git", repository):
        raise RuntimeError("Expected an HTTPS repository URL")
    owned = [d for d in droplets if NAME in d.get("tags", [])]
    database = one([d for d in owned if DB_TAG in d["tags"]], "database hosts")
    apps = [d for d in owned if APP_TAG in d["tags"] and DB_TAG not in d["tags"]]
    owner = (reserved.get("droplet") or {}).get("id")
    old = next((d for d in apps if d["id"] == owner), None)
    if owner and not old:
        raise RuntimeError("Reserved IP is attached to a different host; refusing to move it")
    if apps and not database:
        raise RuntimeError("Database host is missing; refusing to create an empty replacement")
    region = reserved["region"]["slug"]
    vpc = one([v for v in do("vpcs", "list") if v["name"] == NAME], "project VPCs")
    if not vpc:
        if database:
            raise RuntimeError("Database exists without its project VPC; refusing to change networking")
        vpc = first(do("vpcs", "create", "--name", NAME, "--region", region))
    if vpc["region"] != region:
        raise RuntimeError("Reserved IP and VPC must be in the same region")
    if database and (database["vpc_uuid"] != vpc["id"] or database["region"]["slug"] != region):
        raise RuntimeError("Database host is outside the project network")
    # Create firewall protection before provisioning the database.
    for tag in (NAME, APP_TAG, DB_TAG):
        do("compute", "tag", "create", tag)
    firewalls = do("compute", "firewall", "list")
    if not any(f["name"] == DB_TAG for f in firewalls):
        do("compute", "firewall", "create", "--name", DB_TAG, "--tag-names", DB_TAG,
           "--inbound-rules", "protocol:tcp,ports:5432,tag:" + APP_TAG,
           "--outbound-rules", "protocol:tcp,ports:all,address:0.0.0.0/0 protocol:udp,ports:all,address:0.0.0.0/0")
    if not database:
        database = create_host(DB_TAG, DB_TAG, region, vpc["id"],
                               os.environ.get("DATABASE_SIZE", "s-1vcpu-512mb-10gb"),
                               {"DATABASE_PASSWORD": password})
    values = {"DATABASE_PASSWORD": password, "DATABASE_HOST": address(database, "private"),
              "SECRET_KEY_BASE": secret, "HOST": ip.replace(".", "-") + ".sslip.io",
              "REVISION": revision, "REPOSITORY_URL": repository,
              "APPLICATION_COMPOSE": base64.b64encode((ROOT / "compose.application.yaml").read_bytes()).decode()}
    candidate = create_host(APP_TAG + "-" + str(int(time.time())), APP_TAG, region, vpc["id"],
                            os.environ.get("SIZE", "s-1vcpu-2gb"), values)
    switched = False
    try:
        wait_until(lambda: ready("http://" + address(candidate, "public") + "/__deployment", revision))
        # Keep the old application until the candidate has completed migrations and passed health checks.
        switched = True
        assign(ip, candidate["id"])
        wait_until(lambda: ready("https://" + values["HOST"] + "/__deployment", revision), 300)
    except Exception:
        if switched:
            if old:
                assign(ip, old["id"])
            else:
                # Keep the assigned host for diagnosis; never leave the address pointing to a deleted host.
                raise
        delete_application(candidate)
        raise
    for app in apps:
        delete_application(app)
    report("Deployed " + revision + " at https://" + values["HOST"] + ". Database host retained.")


def undeploy(ip, reserved, droplets):
    owned = [d for d in droplets if NAME in d.get("tags", []) or d["name"] == NAME]
    ids = {d["id"] for d in owned}
    owner = (reserved.get("droplet") or {}).get("id") if reserved else None
    if owner and owner not in ids:
        raise RuntimeError("Reserved IP belongs to another project; refusing to delete resources")
    if owner:
        action = first(do("compute", "reserved-ip-action", "unassign", ip))
        result = first(do("compute", "action", "wait", action["id"]))
        if result["status"] != "completed":
            raise RuntimeError("Reserved IP unassignment failed; project servers were retained")
    # Discover retained images before deleting the hosts they belong to.
    snapshots = [s for s in do("compute", "snapshot", "list")
                 if str(s["resource_id"]) in {str(i) for i in ids} or NAME in s.get("tags", [])]
    for snapshot in snapshots:
        do("compute", "snapshot", "delete", snapshot["id"], "--force")
    for droplet in owned:
        do("compute", "droplet", "delete", droplet["id"], "--force")
    wait_until(lambda: not any(d["id"] in ids for d in do("compute", "droplet", "list")), 300)
    if reserved:
        release_ip(ip)
    for firewall in do("compute", "firewall", "list"):
        if firewall["name"] == DB_TAG:
            do("compute", "firewall", "delete", firewall["id"], "--force")
    for vpc in do("vpcs", "list"):
        if vpc["name"] == NAME:
            do("vpcs", "delete", vpc["id"], "--force")
    snapshot_ids = {str(s["id"]) for s in snapshots}
    wait_until(lambda: not any(str(s["id"]) in snapshot_ids for s in do("compute", "snapshot", "list")), 120)
    # These workflows create no automatic cloud backups, separate volumes or managed databases.
    report("Project servers, databases, backups, snapshots and reserved IP removed. "
           "Future project charges stop; accrued usage remains payable.")


def main():
    mode = sys.argv[1] if len(sys.argv) == 2 else ""
    if mode not in ("deploy", "undeploy"):
        raise RuntimeError("Expected deploy or undeploy")
    ip = str(ipaddress.IPv4Address(os.environ["DEMO_RESERVED_IP"]))
    reserved = one([r for r in do("compute", "reserved-ip", "list") if r["ip"] == ip], "reserved IPs")
    droplets = do("compute", "droplet", "list")
    (deploy if mode == "deploy" else undeploy)(ip, reserved, droplets)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, KeyError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
