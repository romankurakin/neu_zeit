"""Always Free OCI infrastructure via Resource Manager; releases via Run Command."""

import argparse
import base64
import hashlib
import io
import ipaddress
import json
import os
import re
import secrets
import shlex
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid
import zipfile
from contextlib import contextmanager
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPOSITORY = ROOT.parent.parent
NAME = "neu-zeit-demo"
OWNER = "neu-zeit-deployment"
ACTIVE = {"ACCEPTED", "IN_PROGRESS", "CANCELING"}
GIB = 1024**3


def report(message):
    print(message, flush=True)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write(message + "\n")


def wait(check, description, seconds=1800):
    deadline, next_report = time.monotonic() + seconds, 0
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        if time.monotonic() >= next_report:
            report("Waiting for " + description)
            next_report = time.monotonic() + 45
        time.sleep(5)
    raise RuntimeError(
        "Timed out waiting for " + description + "; inspect OCI before retrying"
    )


def one(items, description):
    if len(items) > 1:
        raise RuntimeError(
            "Multiple " + description + "; resolve duplicates before continuing"
        )
    return items[0] if items else None


def configuration_zip():
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted((ROOT / "terraform").iterdir()):
            if path.name.endswith((".tf", ".tftpl", ".hcl")):
                archive.write(path, path.name)
        for name in (
            "bootstrap.sh",
            "host.py",
            "compose.application.yaml",
            "compose.database.yaml",
            "compose.proxy.yaml",
        ):
            archive.write(ROOT / name, name)
    return base64.b64encode(stream.getvalue()).decode()


def source_archive(revision):
    result = subprocess.run(
        ["git", "rev-parse", "--verify", revision + "^{commit}"],
        cwd=REPOSITORY,
        check=True,
        capture_output=True,
        text=True,
    )
    sha = result.stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise RuntimeError("Expected a full commit SHA")
    data = subprocess.run(
        ["git", "archive", "--format=tar.gz", sha],
        cwd=REPOSITORY,
        check=True,
        capture_output=True,
    ).stdout
    if len(data) > 100 * 1024**2:
        raise RuntimeError("Source archive exceeds 100 MiB")
    return sha, data, hashlib.sha256(data).hexdigest()


def check_capacity(instances, volumes, stored_bytes, *, new_installation):
    """Conservative allocations, including stopped instances and detached disks."""
    a1 = [i for i in instances if i["shape"] == "VM.Standard.A1.Flex"]
    micro = [i for i in instances if i["shape"] == "VM.Standard.E2.1.Micro"]
    extra_micro, extra_disk = (2, 100) if new_installation else (0, 0)
    if (
        sum(i["ocpus"] for i in a1) > 2
        or sum(i["memory"] for i in a1) > 12
        or len(micro) + extra_micro > 2
        or sum(volumes) + extra_disk > 200
    ):
        raise RuntimeError(
            "Always Free compute/storage capacity is insufficient; no paid fallback is permitted"
        )
    # Reserve 7 GiB for daily dumps and 1 GiB for deployment artifacts in the 10 GB Standard allowance.
    if stored_bytes > 10_000_000_000 - 8 * GIB:
        raise RuntimeError(
            "Other Object Storage data leaves insufficient Always Free backup capacity"
        )


def validate_initial_plan(plan):
    """A retry of a partial first deployment may create missing resources, never replace data."""
    for change in plan.get("resource_changes", []):
        if change.get("mode") == "data":
            continue
        actions = change["change"]["actions"]
        if actions not in (["create"], ["no-op"]):
            raise RuntimeError(
                "Infrastructure plan would modify existing resources: "
                + change["address"]
            )
        after = change["change"].get("after") or {}
        kind = change["type"]
        if kind == "oci_core_instance":
            if after.get("shape") != "VM.Standard.E2.1.Micro":
                raise RuntimeError("Plan must use Always Free Micro instances")
            source = after.get("source_details", [{}])[0]
            if (
                str(source.get("boot_volume_size_in_gbs")) != "50"
                or str(source.get("boot_volume_vpus_per_gb")) != "10"
            ):
                raise RuntimeError("Plan exceeds the fixed free disk configuration")
        allowed = {
            "oci_identity_compartment",
            "oci_identity_dynamic_group",
            "oci_identity_policy",
            "oci_objectstorage_bucket",
            "oci_core_vcn",
            "oci_core_internet_gateway",
            "oci_core_route_table",
            "oci_core_security_list",
            "oci_core_subnet",
            "oci_core_network_security_group",
            "oci_core_network_security_group_security_rule",
            "oci_core_instance",
            "oci_bastion_bastion",
            "oci_core_service_gateway",
        }
        if kind not in allowed:
            raise RuntimeError(
                "Plan contains a resource outside the Always Free design: " + kind
            )
    instances = [
        c for c in plan.get("resource_changes", []) if c["type"] == "oci_core_instance"
    ]
    if len(instances) != 2 or sorted(
        c["change"]["after"]["shape"] for c in instances
    ) != ["VM.Standard.E2.1.Micro", "VM.Standard.E2.1.Micro"]:
        raise RuntimeError(
            "Plan must contain exactly one application and one database Micro host"
        )


class Cloud:
    def __init__(self):
        import oci

        self.oci = oci
        self.pending = False
        config_path = Path(
            os.environ.get("OCI_CONFIG_FILE")
            or os.environ.get("OCI_CLI_CONFIG_FILE", "~/.oci/config")
        ).expanduser()
        if not config_path.is_file():
            raise RuntimeError(
                "OCI login is not configured. Run oci session authenticate and select its OCI_PROFILE."
            )
        config = oci.config.from_file(
            str(config_path),
            os.environ.get("OCI_PROFILE")
            or os.environ.get("OCI_CLI_PROFILE", "DEFAULT"),
        )
        self.tenancy, self.region = config["tenancy"], config["region"]
        self.parent = os.environ.get("OCI_COMPARTMENT_ID") or self.tenancy
        auth = {}
        if config.get("security_token_file"):
            token = Path(os.path.expanduser(config["security_token_file"])).read_text()
            key = oci.signer.load_private_key_from_file(
                os.path.expanduser(config["key_file"])
            )
            auth["signer"] = oci.auth.signers.SecurityTokenSigner(token, key)
        self.identity = oci.identity.IdentityClient(config, **auth)
        self.compute = oci.core.ComputeClient(config, **auth)
        self.block = oci.core.BlockstorageClient(config, **auth)
        self.storage = oci.object_storage.ObjectStorageClient(config, **auth)
        self.orm = oci.resource_manager.ResourceManagerClient(config, **auth)
        self.agent = oci.compute_instance_agent.ComputeInstanceAgentClient(
            config, **auth
        )
        self.bastion = oci.bastion.BastionClient(config, **auth)
        subscriptions = self.identity.list_region_subscriptions(self.tenancy).data
        if not any(
            r.is_home_region and r.region_name == self.region for r in subscriptions
        ):
            raise RuntimeError(
                "OCI profile must select the tenancy home region for Always Free resources"
            )
        self.namespace = self.storage.get_namespace().data

    def listing(self, method, *args, **kwargs):
        return self.oci.pagination.list_call_get_all_results(
            method, *args, **kwargs
        ).data

    def stacks(self):
        return [
            s
            for s in self.listing(self.orm.list_stacks, compartment_id=self.parent)
            if s.display_name == NAME and s.lifecycle_state != "DELETED"
        ]

    def find_stack(self):
        stack = one(self.stacks(), "NeuZeit Resource Manager stacks")
        if stack and not stack.freeform_tags.get(OWNER):
            raise RuntimeError("Stack name is already used by an unowned stack")
        return stack

    def update_tags(self, stack_id, changes, *, etag=None):
        response = self.orm.get_stack(stack_id)
        tags = dict(response.data.freeform_tags)
        for name, value in changes.items():
            if value is None:
                tags.pop(name, None)
            else:
                tags[name] = value
        return self.orm.update_stack(
            stack_id,
            self.oci.resource_manager.models.UpdateStackDetails(freeform_tags=tags),
            if_match=etag or response.headers["etag"],
        ).data

    @contextmanager
    def locked(self, stack):
        response = self.orm.get_stack(stack.id)
        if response.data.freeform_tags.get("operation-lock"):
            raise RuntimeError(
                "Another operation holds this stack lock. If interrupted, inspect OCI and run unlock."
            )
        token = str(uuid.uuid4())
        self.update_tags(
            stack.id, {"operation-lock": token}, etag=response.headers["etag"]
        )
        try:
            yield
        finally:
            try:
                current = self.orm.get_stack(stack.id).data
                if self.pending:
                    report(
                        "Operation may still be running; stack lock retained. Inspect OCI before using unlock."
                    )
                elif current.freeform_tags.get("operation-lock") == token:
                    self.update_tags(stack.id, {"operation-lock": None})
            except self.oci.exceptions.ServiceError as error:
                if error.status != 404:
                    raise

    def state(self, stack):
        try:
            return json.loads(self.orm.get_stack_tf_state(stack.id).data.content)
        except self.oci.exceptions.ServiceError as error:
            if error.status != 404:
                raise
            return {"resources": [], "outputs": {}}

    def preflight(self, stack=None):
        compartments = [self.tenancy] + [
            c.id
            for c in self.listing(
                self.identity.list_compartments,
                self.tenancy,
                compartment_id_in_subtree=True,
                access_level="ANY",
            )
            if c.lifecycle_state == "ACTIVE"
        ]
        domains = self.identity.list_availability_domains(self.tenancy).data
        instances, volumes, stored = [], [], 0
        owner = stack.freeform_tags[OWNER] if stack else None
        for compartment in compartments:
            for instance in self.listing(self.compute.list_instances, compartment):
                if instance.lifecycle_state != "TERMINATED":
                    instances.append(
                        {
                            "shape": instance.shape,
                            "ocpus": getattr(instance.shape_config, "ocpus", 0),
                            "memory": getattr(
                                instance.shape_config, "memory_in_gbs", 0
                            ),
                        }
                    )
            volumes.extend(
                v.size_in_gbs
                for v in self.listing(
                    self.block.list_volumes, compartment_id=compartment
                )
                if v.lifecycle_state != "TERMINATED"
            )
            for domain in domains:
                volumes.extend(
                    v.size_in_gbs
                    for v in self.listing(
                        self.block.list_boot_volumes,
                        availability_domain=domain.name,
                        compartment_id=compartment,
                    )
                    if v.lifecycle_state != "TERMINATED"
                )
            for bucket in self.listing(
                self.storage.list_buckets, self.namespace, compartment, fields=["tags"]
            ):
                if owner and (bucket.freeform_tags or {}).get(OWNER) == owner:
                    continue
                stored += sum(o.size for o in self.list_objects(bucket.name))
        # A partially applied stack already consumes some of the allowance.
        state = self.state(stack) if stack else {"resources": []}
        existing = any(r["type"] == "oci_core_instance" for r in state["resources"])
        if existing and not stack.freeform_tags.get("infrastructure-ready"):
            raise RuntimeError(
                "Partial infrastructure exists. Inspect the failed Resource Manager job; undeploy can clean it up safely."
            )
        check_capacity(
            instances,
            volumes,
            stored,
            new_installation=not (
                stack and stack.freeform_tags.get("infrastructure-ready")
            ),
        )
        return domains

    def create_stack(self, domains):
        models = self.oci.resource_manager.models
        domain = None
        for candidate in domains:
            shapes = {
                s.shape
                for s in self.listing(
                    self.compute.list_shapes,
                    self.parent,
                    availability_domain=candidate.name,
                )
            }
            if "VM.Standard.E2.1.Micro" in shapes:
                domain = candidate.name
                break
        if not domain:
            raise RuntimeError(
                "No availability domain supports Always Free Micro; no paid fallback"
            )
        variables = {
            "tenancy_ocid": self.tenancy,
            "region": self.region,
            "parent_compartment_id": self.parent,
            "availability_domain": domain,
            "namespace": self.namespace,
            "deployment_id": uuid.uuid4().hex[:12],
        }
        images = self.listing(
            self.compute.list_images,
            self.parent,
            operating_system="Oracle Linux",
            operating_system_version="9",
            shape="VM.Standard.E2.1.Micro",
            sort_by="TIMECREATED",
            sort_order="DESC",
        )
        images = [
            i
            for i in images
            if i.lifecycle_state == "AVAILABLE"
            and i.compartment_id is None
            and i.display_name.startswith("Oracle-Linux-9")
        ]
        if not images:
            raise RuntimeError("No Oracle Linux 9 platform image available for Micro")
        variables["image_id"] = images[0].id
        versions = self.orm.list_terraform_versions(
            compartment_id=self.parent
        ).data.items
        version = next(v.name for v in versions if v.is_default)
        stack = self.orm.create_stack(
            models.CreateStackDetails(
                compartment_id=self.parent,
                display_name=NAME,
                terraform_version=version,
                config_source=models.CreateZipUploadConfigSourceDetails(
                    zip_file_base64_encoded=configuration_zip()
                ),
                variables=variables,
                freeform_tags={OWNER: variables["deployment_id"]},
            )
        ).data
        # Concurrent first deployments must never race to create two environments.
        if len(self.stacks()) != 1:
            raise RuntimeError(
                "Concurrent stack creation detected; no infrastructure was applied"
            )
        return stack

    def job(self, stack, operation, plan_id=None):
        models = self.oci.resource_manager.models
        if operation == "PLAN":
            details = models.CreatePlanJobOperationDetails()
        elif operation == "APPLY":
            details = models.CreateApplyJobOperationDetails(
                execution_plan_job_id=plan_id,
                execution_plan_strategy="FROM_PLAN_JOB_ID",
            )
        else:
            details = models.CreateDestroyJobOperationDetails(
                execution_plan_strategy="AUTO_APPROVED"
            )
        request = models.CreateJobDetails(
            stack_id=stack.id, job_operation_details=details
        )
        token = str(uuid.uuid4())
        for delay in (60, 180, 300, 600, 600, None):
            # A lost response may hide an accepted job. Keep the operation lock in that case.
            self.pending = True
            try:
                job = self.orm.create_job(
                    request,
                    opc_retry_token=token,
                    retry_strategy=self.oci.retry.NoneRetryStrategy(),
                ).data
                break
            except self.oci.exceptions.ServiceError as error:
                if 400 <= error.status < 500 and error.status != 408:
                    self.pending = False
                if error.status != 429:
                    raise
                if delay is None:
                    raise RuntimeError(
                        "Oracle still throttles job creation after 29 minutes; "
                        "no job was accepted. Retry later."
                    ) from None
                report(f"Oracle throttled {operation}; retrying in {delay} seconds")
                time.sleep(delay)
        report(operation + " job: " + job.id)

        def complete():
            result = self.orm.get_job(job.id).data
            if result.lifecycle_state in ACTIVE:
                return None
            self.pending = False
            if result.lifecycle_state != "SUCCEEDED":
                raise RuntimeError(
                    operation
                    + " failed; inspect Resource Manager job "
                    + job.id
                    + ". State retained."
                )
            return result

        wait(complete, operation + " job", 3600)
        return job.id

    def provision(self, stack):
        if stack.freeform_tags.get("infrastructure-ready"):
            return
        plan_id = self.job(stack, "PLAN")
        plan = json.loads(
            self.orm.get_job_tf_plan(plan_id, tf_plan_format="JSON").data.content
        )
        validate_initial_plan(plan)
        self.job(stack, "APPLY", plan_id)
        self.update_tags(stack.id, {"infrastructure-ready": "true"})

    def outputs(self, stack):
        values = {
            name: output["value"]
            for name, output in self.state(stack)["outputs"].items()
        }
        required = {
            "compartment_id",
            "application_id",
            "database_id",
            "application_ip",
            "artifacts",
            "backups",
            "namespace",
        }
        if not required <= values.keys():
            raise RuntimeError(
                "Infrastructure outputs are incomplete; inspect Resource Manager before deploying"
            )
        return values

    def verify_hosts(self, stack, output):
        for role in ("application", "database"):
            instance = self.compute.get_instance(output[role + "_id"]).data
            if (
                instance.lifecycle_state != "RUNNING"
                or instance.compartment_id != output["compartment_id"]
                or instance.freeform_tags.get(OWNER) != stack.freeform_tags[OWNER]
                or instance.freeform_tags.get("neu-zeit-role") != role
            ):
                raise RuntimeError(
                    role
                    + " host is missing, stopped, or not owned; no replacement will be created"
                )

    def command(self, output, role, arguments):
        models = self.oci.compute_instance_agent.models
        # Arguments are internally generated SHA values or fixed operation names, never secrets.
        if any(not re.fullmatch(r"[a-z0-9-]+", a) for a in arguments):
            raise RuntimeError("Invalid Run Command argument")
        command = self.agent.create_instance_agent_command(
            models.CreateInstanceAgentCommandDetails(
                compartment_id=output["compartment_id"],
                execution_time_out_in_seconds=3600,
                display_name="NeuZeit " + arguments[0],
                target=models.InstanceAgentCommandTarget(
                    instance_id=output[role + "_id"]
                ),
                content=models.InstanceAgentCommandContent(
                    source=models.InstanceAgentCommandSourceViaTextDetails(
                        text=(
                            "#!/bin/bash\nset -euo pipefail\n"
                            "for _attempt in {1..360}; do\n"
                            "  if test -x /usr/local/sbin/neu-zeit; then break; fi\n  sleep 5\ndone\n"
                            "sudo /usr/local/sbin/neu-zeit "
                            + " ".join(arguments)
                            + "\n"
                        )
                    ),
                    output=models.InstanceAgentCommandOutputViaTextDetails(),
                ),
            )
        ).data
        self.pending = True

        def complete():
            try:
                execution = self.agent.get_instance_agent_command_execution(
                    command.id, output[role + "_id"]
                ).data
            except self.oci.exceptions.ServiceError as error:
                if error.status == 404:
                    return None
                raise
            if execution.lifecycle_state in {"ACCEPTED", "IN_PROGRESS"}:
                return None
            # A timed-out/canceled shell can leave subprocesses running; require operator recovery.
            self.pending = execution.lifecycle_state not in {"SUCCEEDED", "FAILED"}
            if (
                execution.lifecycle_state != "SUCCEEDED"
                or execution.content.exit_code != 0
            ):
                raise RuntimeError(
                    "Run Command failed on "
                    + role
                    + ": "
                    + command.id
                    + ". Database retained."
                )
            return True

        wait(complete, role + " " + arguments[0], 4500)

    def list_objects(self, bucket):
        objects, start = [], None
        while True:
            result = self.storage.list_objects(
                self.namespace, bucket, fields="name,size", start=start
            ).data
            objects.extend(result.objects)
            if not result.next_start_with:
                return objects
            start = result.next_start_with

    def put(self, bucket, name, content, *, create_only=False):
        kwargs = {"if_none_match": "*"} if create_only else {}
        self.storage.put_object(self.namespace, bucket, name, content, **kwargs)

    def initialize_secrets(self, output):
        bucket = output["artifacts"]
        names = {o.name for o in self.list_objects(bucket)}
        bootstrap = {"bootstrap/application.json", "bootstrap/database.json"}
        if bootstrap <= names:
            return
        if "bootstrap/application.json" in names:
            raise RuntimeError(
                "Initial database credentials are missing; recover the bootstrap object before deploying"
            )
        if "bootstrap/database.json" in names:
            password = json.loads(
                self.storage.get_object(
                    self.namespace, bucket, "bootstrap/database.json"
                ).data.content
            )["database_password"]
        else:
            password = secrets.token_hex(32)
            self.put(
                bucket,
                "bootstrap/database.json",
                json.dumps({"database_password": password}).encode(),
                create_only=True,
            )
        self.put(
            bucket,
            "bootstrap/application.json",
            json.dumps(
                {
                    "database_password": password,
                    "secret_key_base": secrets.token_hex(64),
                    "hostname": output["application_ip"].replace(".", "-")
                    + ".sslip.io",
                }
            ).encode(),
            create_only=True,
        )

    def release(self, stack, revision, archive, digest):
        output = self.outputs(stack)
        self.verify_hosts(stack, output)
        current = self.orm.get_stack(stack.id).data
        if current.freeform_tags.get("destroying"):
            raise RuntimeError(
                "Undeploy has started; finish undeploy before creating a new installation"
            )
        if not current.freeform_tags.get("database-ready"):
            self.initialize_secrets(output)
            self.command(output, "database", ["init"])
            self.update_tags(stack.id, {"database-ready": "true"})
        self.command(output, "database", ["check"])
        self.command(output, "database", ["backup"])
        self.command(output, "application", ["init"])
        # Retain only one source archive; built rollback images remain on the application server.
        for obj in self.list_objects(output["artifacts"]):
            if obj.name.startswith("releases/"):
                self.storage.delete_object(
                    self.namespace, output["artifacts"], obj.name
                )
        self.put(output["artifacts"], "releases/" + revision + ".tar.gz", archive)
        self.command(output, "application", ["deploy", revision, digest])
        report(
            "Deployed "
            + revision
            + " at https://"
            + output["application_ip"].replace(".", "-")
            + ".sslip.io. PostgreSQL and its credentials were retained."
        )

    def close_session(self, session_id):
        try:
            self.bastion.delete_session(session_id)

            def deleted():
                try:
                    return (
                        self.bastion.get_session(session_id).data.lifecycle_state
                        == "DELETED"
                    )
                except self.oci.exceptions.ServiceError as error:
                    if error.status == 404:
                        return True
                    raise

            wait(deleted, "console session deletion", 300)
        except self.oci.exceptions.ServiceError as error:
            if error.status != 404:
                raise

    def console(self, stack, role, tool, client_ip=None):
        if (
            tool == "iex"
            and role != "application"
            or tool == "psql"
            and role != "database"
        ):
            raise RuntimeError(
                "IEx requires --role application; psql requires --role database"
            )
        if not client_ip:
            with urllib.request.urlopen(
                "https://api.ipify.org", timeout=10
            ) as response:
                client_ip = response.read(64).decode().strip()
        address = ipaddress.IPv4Address(client_ip)
        if not address.is_global:
            raise RuntimeError("Console requires a public IPv4 address")
        models = self.oci.bastion.models
        session_id = None
        with tempfile.TemporaryDirectory(prefix="neu-zeit-console-") as temporary:
            key = Path(temporary) / "key"
            subprocess.run(
                [
                    "ssh-keygen",
                    "-q",
                    "-t",
                    "rsa",
                    "-b",
                    "3072",
                    "-N",
                    "",
                    "-f",
                    str(key),
                ],
                check=True,
            )
            try:
                # Release the deployment lock before entering an interactive terminal.
                with self.locked(stack):
                    if self.orm.get_stack(stack.id).data.freeform_tags.get(
                        "destroying"
                    ):
                        raise RuntimeError(
                            "Undeploy has started; no new consoles are allowed"
                        )
                    output = self.outputs(stack)
                    self.verify_hosts(stack, output)
                    bastion_id = output["bastion_id"]
                    sessions = self.listing(self.bastion.list_sessions, bastion_id)
                    if any(
                        s.lifecycle_state not in {"DELETED", "FAILED"} for s in sessions
                    ):
                        raise RuntimeError(
                            "A console session already exists; close it or wait for its 30-minute expiry"
                        )
                    self.bastion.update_bastion(
                        bastion_id,
                        models.UpdateBastionDetails(
                            client_cidr_block_allow_list=[str(address) + "/32"]
                        ),
                    )
                    wait(
                        lambda: (
                            self.bastion.get_bastion(bastion_id).data.lifecycle_state
                            == "ACTIVE"
                        ),
                        "Bastion configuration",
                        300,
                    )
                    session = self.bastion.create_session(
                        models.CreateSessionDetails(
                            bastion_id=bastion_id,
                            display_name="neu-zeit-" + role,
                            key_type="PUB",
                            key_details=models.PublicKeyDetails(
                                public_key_content=key.with_suffix(".pub").read_text()
                            ),
                            session_ttl_in_seconds=1800,
                            target_resource_details=models.CreateManagedSshSessionTargetResourceDetails(
                                target_resource_id=output[role + "_id"],
                                target_resource_operating_system_user_name="opc",
                                target_resource_port=22,
                            ),
                        )
                    ).data
                    session_id = session.id

                    def ready():
                        state = self.bastion.get_session(
                            session_id
                        ).data.lifecycle_state
                        if state in {"FAILED", "DELETING", "DELETED"}:
                            raise RuntimeError(
                                "Console session failed; check the Bastion agent on the target host"
                            )
                        return state == "ACTIVE"

                    wait(ready, "console access", 600)
                proxy = shlex.join(
                    [
                        "ssh",
                        "-i",
                        str(key),
                        "-o",
                        "IdentitiesOnly=yes",
                        "-o",
                        "ForwardAgent=no",
                        "-o",
                        "StrictHostKeyChecking=accept-new",
                        "-W",
                        "%h:%p",
                        "-p",
                        "22",
                        session_id
                        + "@host.bastion."
                        + self.region
                        + ".oci.oraclecloud.com",
                    ]
                )
                target = "10.42.0.10" if role == "application" else "10.42.0.20"
                remote = (
                    ["sudo", "-i"]
                    if tool == "shell"
                    else [
                        "sudo",
                        "/opt/neu-zeit/sdk/bin/python",
                        "/opt/neu-zeit/host.py",
                        "console",
                        tool,
                    ]
                )
                report(
                    "Opening " + role + " " + tool + "; access expires after 30 minutes"
                )
                subprocess.run(
                    [
                        "ssh",
                        "-t",
                        "-i",
                        str(key),
                        "-o",
                        "IdentitiesOnly=yes",
                        "-o",
                        "ForwardAgent=no",
                        "-o",
                        "StrictHostKeyChecking=accept-new",
                        "-o",
                        "HostKeyAlias=" + output[role + "_id"],
                        "-o",
                        "ProxyCommand=" + proxy,
                        "opc@" + target,
                        *remote,
                    ],
                    check=True,
                )
            finally:
                if session_id:
                    self.close_session(session_id)

    def destroy(self, stack):
        self.update_tags(stack.id, {"destroying": "true"})
        state = self.state(stack)
        resources = state.get("resources", [])
        compartment_ids = [
            i["attributes"]["id"]
            for r in resources
            if r["type"] == "oci_identity_compartment"
            for i in r.get("instances", [])
        ]
        if not compartment_ids and resources:
            raise RuntimeError(
                "Cannot identify the owned compartment; state retained for recovery"
            )
        for resource in resources:
            if resource["type"] == "oci_bastion_bastion":
                for instance in resource.get("instances", []):
                    for session in self.listing(
                        self.bastion.list_sessions, instance["attributes"]["id"]
                    ):
                        if session.lifecycle_state != "DELETED":
                            self.close_session(session.id)
        owner = stack.freeform_tags[OWNER]
        for compartment in compartment_ids:
            instances = self.listing(self.compute.list_instances, compartment)
            boot_ids = set()
            for instance in instances:
                if instance.freeform_tags.get(OWNER) != owner:
                    raise RuntimeError(
                        "Foreign instance in the demo compartment; cleanup stopped"
                    )
                if instance.lifecycle_state == "TERMINATED":
                    continue
                for attachment in self.listing(
                    self.compute.list_boot_volume_attachments,
                    instance.availability_domain,
                    compartment,
                    instance_id=instance.id,
                ):
                    boot_ids.add(attachment.boot_volume_id)
                # Stop all writers before removing backup objects, even if Run Command is broken.
                if instance.lifecycle_state == "RUNNING":
                    self.compute.instance_action(instance.id, "STOP")
                wait(
                    lambda instance_id=instance.id: (
                        self.compute.get_instance(instance_id).data.lifecycle_state
                        in {"STOPPED", "TERMINATED"}
                    ),
                    "host shutdown",
                    900,
                )
            for backup in self.listing(
                self.block.list_boot_volume_backups, compartment
            ):
                if (
                    backup.boot_volume_id in boot_ids
                    or backup.freeform_tags.get(OWNER) == owner
                ):
                    if backup.lifecycle_state != "TERMINATED":
                        self.block.delete_boot_volume_backup(backup.id)
                        wait(
                            lambda backup_id=backup.id: (
                                self.block.get_boot_volume_backup(
                                    backup_id
                                ).data.lifecycle_state
                                == "TERMINATED"
                            ),
                            "boot backup deletion",
                            900,
                        )
                elif backup.lifecycle_state != "TERMINATED":
                    raise RuntimeError(
                        "Foreign backup in the demo compartment; cleanup stopped"
                    )
            for bucket in self.listing(
                self.storage.list_buckets, self.namespace, compartment
            ):
                details = self.storage.get_bucket(self.namespace, bucket.name).data
                if (
                    details.freeform_tags.get(OWNER) != owner
                    or details.versioning != "Disabled"
                ):
                    raise RuntimeError(
                        "Unowned or versioned bucket requires review; state retained"
                    )
                for obj in self.list_objects(bucket.name):
                    self.storage.delete_object(self.namespace, bucket.name, obj.name)
        self.job(stack, "DESTROY")
        remaining = self.state(stack).get("resources", [])
        if any(
            r.get("mode", "managed") == "managed" and r.get("instances")
            for r in remaining
        ):
            raise RuntimeError(
                "Terraform still tracks resources; stack retained for cleanup"
            )
        # The child compartment cannot be deleted by OCI while it still contains live resources.
        for compartment in compartment_ids:
            wait(
                lambda compartment_id=compartment: (
                    self.identity.get_compartment(compartment_id).data.lifecycle_state
                    == "DELETED"
                ),
                "compartment deletion",
                1800,
            )
        self.orm.delete_stack(stack.id)
        report(
            "Oracle demo removed: servers, PostgreSQL data, backups, buckets, network, IAM resources and stack."
        )

    def unlock(self, stack):
        jobs = self.listing(self.orm.list_jobs, stack_id=stack.id)
        if any(j.lifecycle_state in ACTIVE for j in jobs):
            raise RuntimeError("A Resource Manager job is still running; lock retained")
        output = {
            name: value["value"]
            for name, value in self.state(stack).get("outputs", {}).items()
        }
        if output.get("compartment_id"):
            commands = self.listing(
                self.agent.list_instance_agent_commands, output["compartment_id"]
            )
            for command in commands:
                detail = self.agent.get_instance_agent_command(
                    command.instance_agent_command_id
                ).data
                execution = self.agent.get_instance_agent_command_execution(
                    command.instance_agent_command_id, detail.target.instance_id
                ).data
                if execution.lifecycle_state in ACTIVE:
                    raise RuntimeError(
                        "A Run Command operation is still running; lock retained"
                    )
        # Do not infer an abandoned caller from elapsed time. An operator must verify Run Command too.
        self.update_tags(stack.id, {"operation-lock": None})
        report("Operation lock cleared after operator recovery request")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "operation", choices=["deploy", "undeploy", "console", "unlock", "package"]
    )
    parser.add_argument("--revision", default="HEAD")
    parser.add_argument(
        "--output", type=Path, default=REPOSITORY / "tmp/oracle-stack.zip"
    )
    parser.add_argument(
        "--role", choices=["application", "database"], default="application"
    )
    parser.add_argument("--tool", choices=["shell", "iex", "psql"], default="shell")
    parser.add_argument(
        "--client-ip",
        help="Public IPv4 address; otherwise detected using api.ipify.org",
    )
    args = parser.parse_args()
    if args.operation == "package":
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(base64.b64decode(configuration_zip()))
        report("Resource Manager configuration: " + str(args.output))
        return
    release = source_archive(args.revision) if args.operation == "deploy" else None
    cloud = Cloud()
    stack = cloud.find_stack()
    if args.operation == "deploy":
        domains = cloud.preflight(stack)
        stack = stack or cloud.create_stack(domains)
        with cloud.locked(stack):
            cloud.provision(stack)
            cloud.release(stack, *release)
    elif args.operation == "undeploy":
        if not stack:
            report("No Oracle demo stack exists")
            return
        with cloud.locked(stack):
            cloud.destroy(stack)
    elif args.operation == "console":
        if not stack:
            raise RuntimeError("Deploy the Oracle demo first")
        cloud.console(stack, args.role, args.tool, args.client_ip)
    elif stack:
        cloud.unlock(stack)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except Exception as error:
        # OCI exception bodies and subprocess output may include request data. Keep them private.
        print(
            type(error).__name__
            + ": OCI operation failed. Check authentication, permissions and the OCI job/command status.",
            file=sys.stderr,
        )
        sys.exit(1)
