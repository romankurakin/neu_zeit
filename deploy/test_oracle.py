"""Regression checks for Oracle deployment data preservation and cleanup."""

import copy
import importlib.util
import io
import json
import tarfile
import tempfile
import unittest
from contextlib import nullcontext
from pathlib import Path
from types import SimpleNamespace as NS
from unittest.mock import Mock, patch


def load(name, filename):
    spec = importlib.util.spec_from_file_location(
        name, Path(__file__).parent / "oracle" / filename
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


demo = load("oracle_demo", "demo.py")
host = load("oracle_host", "host.py")
OLD, NEW = "a" * 40, "b" * 40


def initial_plan():
    return {
        "resource_changes": [
            {
                "address": "oci_core_instance.host[" + role + "]",
                "type": "oci_core_instance",
                "change": {
                    "actions": ["create"],
                    "after": {
                        "shape": "VM.Standard.E2.1.Micro",
                        "source_details": [
                            {
                                "boot_volume_size_in_gbs": 50,
                                "boot_volume_vpus_per_gb": 10,
                            }
                        ],
                    },
                },
            }
            for role in ("application", "database")
        ]
    }


class FreeTierTests(unittest.TestCase):
    def test_fixed_installation_fits_free_capacity(self):
        demo.check_capacity([], [], 0, new_installation=True)
        demo.validate_initial_plan(initial_plan())

    def test_existing_stopped_allocations_prevent_paid_overflow(self):
        with self.assertRaisesRegex(RuntimeError, "Always Free"):
            demo.check_capacity(
                [{"shape": "VM.Standard.E2.1.Micro", "ocpus": 0.125, "memory": 1}],
                [],
                0,
                new_installation=True,
            )

    def test_detached_disks_and_other_bucket_data_count(self):
        for volumes, stored in [([101], 0), ([], 2 * demo.GIB)]:
            with self.assertRaises(RuntimeError):
                demo.check_capacity([], volumes, stored, new_installation=True)

    def test_repeat_deploy_does_not_reserve_another_two_servers(self):
        demo.check_capacity(
            [
                {"shape": "VM.Standard.E2.1.Micro", "ocpus": 0.125, "memory": 1},
                {"shape": "VM.Standard.E2.1.Micro", "ocpus": 0.125, "memory": 1},
            ],
            [50, 50],
            0,
            new_installation=False,
        )

    def test_plan_cannot_replace_or_update_database(self):
        for actions in (["delete", "create"], ["update"], ["delete"]):
            plan = initial_plan()
            plan["resource_changes"][1]["change"]["actions"] = actions
            with self.assertRaisesRegex(RuntimeError, "modify existing"):
                demo.validate_initial_plan(plan)

    def test_plan_cannot_add_extra_free_servers_or_paid_resources(self):
        plan = initial_plan()
        plan["resource_changes"].append(copy.deepcopy(plan["resource_changes"][0]))
        with self.assertRaisesRegex(RuntimeError, "exactly one"):
            demo.validate_initial_plan(plan)
        plan = initial_plan()
        plan["resource_changes"].append(
            {
                "address": "paid",
                "type": "oci_database_db_system",
                "change": {"actions": ["create"], "after": {}},
            }
        )
        with self.assertRaisesRegex(RuntimeError, "outside"):
            demo.validate_initial_plan(plan)

    def test_other_shapes_and_paid_disk_performance_are_rejected(self):
        for field, value in [
            ("shape", "VM.Standard.E4.Flex"),
            ("shape", "VM.Standard.A1.Flex"),
            (
                "source_details",
                [{"boot_volume_size_in_gbs": 50, "boot_volume_vpus_per_gb": 20}],
            ),
        ]:
            plan = initial_plan()
            plan["resource_changes"][0]["change"]["after"][field] = value
            with self.assertRaises(RuntimeError):
                demo.validate_initial_plan(plan)


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.cloud = object.__new__(demo.Cloud)
        self.cloud.namespace = "ns"
        self.cloud.orm = Mock()
        self.cloud.storage = Mock()
        self.stack = NS(
            id="stack",
            freeform_tags={demo.OWNER: "owned", "infrastructure-ready": "true"},
        )
        self.output = {
            "artifacts": "artifacts",
            "backups": "backups",
            "application_ip": "192.0.2.1",
        }
        self.cloud.outputs = Mock(return_value=self.output)
        self.cloud.verify_hosts = Mock()
        self.cloud.command = Mock()
        self.cloud.list_objects = Mock(return_value=[])
        self.cloud.put = Mock()
        self.cloud.orm.get_stack.return_value.data = NS(
            freeform_tags={"database-ready": "true"}
        )

    def test_repeat_deploy_never_applies_terraform(self):
        self.cloud.job = Mock()
        self.cloud.provision(self.stack)
        self.cloud.job.assert_not_called()

    def test_repeat_capacity_check_requests_bucket_tags_and_counts_unowned_data(self):
        self.cloud.tenancy = "tenancy"
        self.cloud.identity = Mock()
        self.cloud.identity.list_availability_domains.return_value.data = []
        self.cloud.compute = Mock()
        self.cloud.block = Mock()
        self.cloud.state = Mock(return_value={"resources": []})

        def listing(method, *args, **kwargs):
            if method == self.cloud.storage.list_buckets:
                # OCI omits tags unless explicitly requested, even for owned buckets.
                tags = (
                    {demo.OWNER: "owned"} if kwargs.get("fields") == ["tags"] else None
                )
                return [
                    NS(name="owned", freeform_tags=tags),
                    NS(name="unowned", freeform_tags=None),
                ]
            return []

        self.cloud.listing = listing
        self.cloud.list_objects.side_effect = lambda name: [
            NS(size=8 * demo.GIB if name == "owned" else 123)
        ]
        with patch.object(demo, "check_capacity") as capacity:
            self.cloud.preflight(self.stack)
        capacity.assert_called_once_with([], [], 123, new_installation=False)

    def test_repeat_release_keeps_database_and_credentials(self):
        self.cloud.initialize_secrets = Mock()
        with patch.object(demo, "report"):
            self.cloud.release(self.stack, NEW, b"archive", "c" * 64)
        self.cloud.initialize_secrets.assert_not_called()
        operations = [
            (c.args[1], c.args[2][0]) for c in self.cloud.command.call_args_list
        ]
        self.assertEqual(
            operations,
            [
                ("database", "check"),
                ("database", "backup"),
                ("application", "init"),
                ("application", "deploy"),
            ],
        )

    def test_missing_host_stops_before_upload_or_commands(self):
        self.cloud.verify_hosts.side_effect = RuntimeError("database missing")
        with self.assertRaisesRegex(RuntimeError, "database missing"):
            self.cloud.release(self.stack, NEW, b"archive", "c" * 64)
        self.cloud.put.assert_not_called()
        self.cloud.command.assert_not_called()

    def test_undeploy_marker_prevents_release(self):
        self.cloud.orm.get_stack.return_value.data.freeform_tags["destroying"] = "true"
        with self.assertRaisesRegex(RuntimeError, "Undeploy has started"):
            self.cloud.release(self.stack, NEW, b"archive", "c" * 64)
        self.cloud.command.assert_not_called()

    def test_initial_secrets_survive_interrupted_second_upload(self):
        self.cloud.list_objects.return_value = [NS(name="bootstrap/database.json")]
        self.cloud.storage.get_object.return_value.data.content = json.dumps(
            {"database_password": "d" * 64}
        ).encode()
        self.cloud.initialize_secrets(self.output)
        self.assertEqual(self.cloud.put.call_count, 1)
        payload = json.loads(self.cloud.put.call_args.args[2])
        self.assertEqual(payload["database_password"], "d" * 64)
        self.assertTrue(self.cloud.put.call_args.kwargs["create_only"])

    def test_existing_secrets_are_never_overwritten(self):
        self.cloud.list_objects.return_value = [
            NS(name="bootstrap/" + role + ".json")
            for role in ("application", "database")
        ]
        self.cloud.initialize_secrets(self.output)
        self.cloud.put.assert_not_called()

    def test_remote_timeout_retains_operation_lock(self):
        class ServiceError(Exception):
            pass

        self.cloud.oci = NS(exceptions=NS(ServiceError=ServiceError))
        self.cloud.pending = True
        self.cloud.update_tags = Mock()
        self.cloud.orm.get_stack.return_value = NS(
            data=NS(freeform_tags={}), headers={"etag": "etag"}
        )
        with patch.object(demo, "report"), self.cloud.locked(self.stack):
            pass
        self.assertEqual(self.cloud.update_tags.call_count, 1)

    def test_failed_destroy_keeps_resource_manager_state(self):
        self.cloud.update_tags = Mock()
        self.cloud.state = Mock(return_value={"resources": []})
        self.cloud.job = Mock(side_effect=RuntimeError("destroy failed"))
        with self.assertRaisesRegex(RuntimeError, "destroy failed"):
            self.cloud.destroy(self.stack)
        self.cloud.orm.delete_stack.assert_not_called()

    def test_destroy_stops_writers_before_purging_buckets(self):
        self.cloud.update_tags = Mock()
        self.cloud.state = Mock(
            side_effect=[
                {
                    "resources": [
                        {
                            "type": "oci_identity_compartment",
                            "instances": [{"attributes": {"id": "compartment"}}],
                        }
                    ]
                },
                {"resources": []},
            ]
        )
        self.cloud.compute = Mock()
        self.cloud.block = Mock()
        self.cloud.identity = Mock()
        self.cloud.job = Mock()
        events = []
        instance = NS(
            id="database",
            freeform_tags={demo.OWNER: "owned"},
            lifecycle_state="RUNNING",
            availability_domain="AD",
        )
        self.cloud.compute.get_instance.return_value.data.lifecycle_state = "STOPPED"
        self.cloud.identity.get_compartment.return_value.data.lifecycle_state = (
            "DELETED"
        )

        def listing(method, *args, **kwargs):
            if method == self.cloud.compute.list_instances:
                return [instance]
            if method == self.cloud.storage.list_buckets:
                return [NS(name="backups")]
            return []

        self.cloud.listing = listing
        self.cloud.storage.get_bucket.return_value.data = NS(
            freeform_tags={demo.OWNER: "owned"}, versioning="Disabled"
        )
        self.cloud.list_objects.return_value = [NS(name="day-0.dump")]
        self.cloud.compute.instance_action.side_effect = lambda *a: events.append(
            "stop"
        )
        self.cloud.storage.delete_object.side_effect = lambda *a: events.append("purge")
        self.cloud.job.side_effect = lambda *a: events.append("destroy")
        self.cloud.orm.delete_stack.side_effect = lambda *a: events.append("forget")
        with patch.object(demo, "report"):
            self.cloud.destroy(self.stack)
        self.assertEqual(events, ["stop", "purge", "destroy", "forget"])


class JobTests(unittest.TestCase):
    class ServiceError(Exception):
        def __init__(self, status):
            self.status = status

    def setUp(self):
        self.cloud = object.__new__(demo.Cloud)
        self.cloud.pending = False
        self.cloud.oci = NS(
            resource_manager=NS(
                models=NS(CreatePlanJobOperationDetails=NS, CreateJobDetails=NS)
            ),
            retry=NS(NoneRetryStrategy=NS),
            exceptions=NS(ServiceError=self.ServiceError),
        )
        self.cloud.orm = Mock()
        self.cloud.orm.get_job.return_value.data.lifecycle_state = "SUCCEEDED"
        self.stack = NS(id="stack")

    def test_throttled_submission_reuses_idempotency_token(self):
        self.cloud.orm.create_job.side_effect = [
            self.ServiceError(429),
            self.ServiceError(429),
            NS(data=NS(id="job")),
        ]
        with patch.object(demo.time, "sleep") as sleep, patch.object(demo, "report"):
            self.assertEqual(self.cloud.job(self.stack, "PLAN"), "job")
        requests = self.cloud.orm.create_job.call_args_list
        self.assertEqual(len({c.kwargs["opc_retry_token"] for c in requests}), 1)
        self.assertEqual([c.args[0] for c in sleep.call_args_list], [60, 180])
        self.assertFalse(self.cloud.pending)

    def test_persistent_throttling_is_bounded_and_leaves_no_pending_job(self):
        self.cloud.orm.create_job.side_effect = self.ServiceError(429)
        with (
            patch.object(demo.time, "sleep") as sleep,
            patch.object(demo, "report"),
            self.assertRaisesRegex(RuntimeError, "no job was accepted"),
        ):
            self.cloud.job(self.stack, "PLAN")
        self.assertEqual(sum(c.args[0] for c in sleep.call_args_list), 29 * 60)
        self.assertFalse(self.cloud.pending)

    def test_authentication_failure_is_not_retried(self):
        self.cloud.orm.create_job.side_effect = self.ServiceError(401)
        with self.assertRaises(self.ServiceError):
            self.cloud.job(self.stack, "PLAN")
        self.cloud.orm.create_job.assert_called_once()
        self.assertFalse(self.cloud.pending)

    def test_lost_submission_response_retains_operation_lock(self):
        self.cloud.orm.create_job.side_effect = TimeoutError()
        with self.assertRaises(TimeoutError):
            self.cloud.job(self.stack, "PLAN")
        self.cloud.orm.create_job.assert_called_once()
        self.assertTrue(self.cloud.pending)


class ConsoleCleanupTests(unittest.TestCase):
    def setUp(self):
        self.cloud = object.__new__(demo.Cloud)
        self.cloud.bastion = Mock()
        self.cloud.oci = NS(exceptions=NS(ServiceError=JobTests.ServiceError))

    def test_expired_session_needs_no_second_delete(self):
        self.cloud.bastion.get_session.return_value.data.lifecycle_state = "DELETED"
        self.cloud.close_session("session")
        self.cloud.bastion.delete_session.assert_not_called()

    def test_expiry_racing_with_delete_is_awaited(self):
        self.cloud.bastion.get_session.side_effect = [
            NS(data=NS(lifecycle_state=state))
            for state in ["ACTIVE", "DELETING", "DELETED"]
        ]
        self.cloud.bastion.delete_session.side_effect = JobTests.ServiceError(409)
        self.cloud.close_session("session")
        self.cloud.bastion.delete_session.assert_called_once_with("session")

    def test_other_delete_conflicts_are_not_hidden(self):
        self.cloud.bastion.get_session.return_value.data.lifecycle_state = "ACTIVE"
        self.cloud.bastion.delete_session.side_effect = JobTests.ServiceError(409)
        with self.assertRaises(JobTests.ServiceError):
            self.cloud.close_session("session")


class ConsoleTests(unittest.TestCase):
    def setUp(self):
        self.cloud = object.__new__(demo.Cloud)
        self.cloud.region = "eu-amsterdam-1"
        self.cloud.oci = NS(
            bastion=NS(
                models=NS(
                    UpdateBastionDetails=NS,
                    CreateSessionDetails=NS,
                    PublicKeyDetails=NS,
                    CreateManagedSshSessionTargetResourceDetails=NS,
                )
            )
        )
        self.cloud.bastion = Mock()
        self.cloud.bastion.get_bastion.return_value.data.lifecycle_state = "ACTIVE"
        self.cloud.bastion.get_session.return_value.data.lifecycle_state = "ACTIVE"
        self.cloud.bastion.create_session.return_value.data.id = "session"
        self.cloud.orm = Mock()
        self.cloud.orm.get_stack.return_value.data.freeform_tags = {}
        self.cloud.outputs = Mock(
            return_value={
                "bastion_id": "bastion",
                "application_id": "application",
                "database_id": "database",
            }
        )
        self.cloud.verify_hosts = Mock()
        self.cloud.listing = Mock(return_value=[])
        self.cloud.close_session = Mock()
        self.cloud.locked = Mock(side_effect=lambda _: nullcontext())
        self.calls = []

        def run(args, **kwargs):
            self.calls.append(args)
            if args[0] == "ssh-keygen":
                self.key = Path(args[-1])
                self.key.write_text("private, never uploaded")
                self.key.with_suffix(".pub").write_text("ssh-rsa public")

        self.run = patch.object(demo.subprocess, "run", side_effect=run)
        self.run.start()
        self.addCleanup(self.run.stop)

    def test_only_public_ephemeral_key_is_sent_and_deleted_after_session(self):
        with patch.object(demo, "report"):
            self.cloud.console(NS(id="stack"), "application", "iex", "8.8.8.8")
        request = self.cloud.bastion.create_session.call_args.args[0]
        self.assertRegex(request.display_name, r"^[a-zA-Z0-9._+@-]+$")
        self.assertEqual(request.key_details.public_key_content, "ssh-rsa public")
        self.assertEqual(request.session_ttl_in_seconds, 1800)
        self.assertEqual(
            request.target_resource_details.target_resource_id, "application"
        )
        self.assertEqual(
            self.cloud.bastion.update_bastion.call_args.args[
                1
            ].client_cidr_block_allow_list,
            ["8.8.8.8/32"],
        )
        self.cloud.close_session.assert_called_once_with("session")
        self.assertFalse(self.key.exists())
        self.assertIn("StrictHostKeyChecking=accept-new", self.calls[-1])
        self.assertEqual(self.calls[-1][-2:], ["console", "iex"])

    def test_session_creation_failure_still_revokes_access_and_removes_key(self):
        self.cloud.bastion.get_session.return_value.data.lifecycle_state = "FAILED"
        with self.assertRaisesRegex(RuntimeError, "session failed"):
            self.cloud.console(NS(id="stack"), "database", "psql", "8.8.8.8")
        self.cloud.close_session.assert_called_once_with("session")
        self.assertFalse(self.key.exists())
        self.assertEqual(len(self.calls), 1)

    def test_existing_operator_session_is_not_interrupted(self):
        self.cloud.listing.return_value = [NS(lifecycle_state="ACTIVE")]
        with self.assertRaisesRegex(RuntimeError, "already exists"):
            self.cloud.console(NS(id="stack"), "application", "shell", "8.8.8.8")
        self.cloud.bastion.update_bastion.assert_not_called()
        self.cloud.close_session.assert_not_called()
        self.assertFalse(self.key.exists())

    def test_console_cannot_open_during_undeploy(self):
        self.cloud.orm.get_stack.return_value.data.freeform_tags = {
            "destroying": "true"
        }
        with self.assertRaisesRegex(RuntimeError, "Undeploy"):
            self.cloud.console(NS(id="stack"), "application", "shell", "8.8.8.8")
        self.cloud.bastion.create_session.assert_not_called()

    def test_private_client_address_is_rejected_before_cloud_changes(self):
        with self.assertRaisesRegex(RuntimeError, "public IPv4"):
            self.cloud.console(NS(id="stack"), "application", "shell", "127.0.0.1")
        self.cloud.locked.assert_not_called()


class HostTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        self.root_patch = patch.object(host, "ROOT", self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        (self.root / "application.env").write_text("stable credentials")
        (self.root / "hostname").write_text("192-0-2-1.sslip.io")
        (self.root / "current.json").write_text(
            json.dumps({"slot": "blue", "revision": OLD})
        )

    def deployment(self, *, fail_at=None):
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w:gz"):
            pass
        payload = archive.getvalue()
        calls, activated = [], []

        def compose(kind, *args, **kwargs):
            calls.append((kind, args, kwargs))
            if fail_at == "migration" and args[:1] == ("run",):
                raise RuntimeError("migration failed")
            if fail_at == "health" and args[:1] == ("up",):
                raise RuntimeError("health failed")

        def ready(*args):
            if fail_at == "https":
                raise RuntimeError("https failed")

        with (
            patch.object(host, "fetch", return_value=payload),
            patch.object(host, "run"),
            patch.object(host, "compose", side_effect=compose),
            patch.object(host, "activate", side_effect=activated.append),
            patch.object(host, "https_ready", side_effect=ready),
            patch.object(
                host.subprocess, "run", return_value=NS(stdout=OLD + "\n" + NEW)
            ),
        ):
            if fail_at:
                with self.assertRaises(RuntimeError):
                    host.deploy({}, NEW, host.hashlib.sha256(payload).hexdigest())
            else:
                host.deploy({}, NEW, host.hashlib.sha256(payload).hexdigest())
        return calls, activated

    def test_success_updates_application_slot_without_touching_database(self):
        calls, _ = self.deployment()
        self.assertFalse(any(c[0] == "database" for c in calls))
        self.assertEqual(
            json.loads((self.root / "current.json").read_text()),
            {"slot": "green", "revision": NEW},
        )
        self.assertEqual(
            (self.root / "application.env").read_text(), "stable credentials"
        )

    def test_migration_health_and_https_failure_keep_current_release(self):
        for failure in ("migration", "health", "https"):
            calls, activated = self.deployment(fail_at=failure)
            self.assertEqual(
                json.loads((self.root / "current.json").read_text())["revision"], OLD
            )
            self.assertIn(OLD, activated[-1])
            self.assertFalse(any(c[0] == "database" for c in calls))

    def test_missing_database_data_is_never_reinitialized(self):
        (self.root / "database.env").write_text("POSTGRES_PASSWORD=stable")
        (self.root / "database-ready").touch()
        with (
            patch.object(host, "compose") as compose,
            self.assertRaisesRegex(RuntimeError, "empty replacement"),
        ):
            host.initialize({"role": "database"})
        compose.assert_not_called()

    def test_source_archive_cannot_escape_build_directory(self):
        path = self.root / "source.tar.gz"
        with tarfile.open(path, "w:gz") as archive:
            member = tarfile.TarInfo("../../outside")
            member.size = 1
            archive.addfile(member, io.BytesIO(b"x"))
        with self.assertRaisesRegex(RuntimeError, "Unsafe path"):
            host.unpack(path, self.root / "build")

    def test_secret_files_are_private(self):
        path = self.root / "secrets"
        host.write(path, "secret")
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
