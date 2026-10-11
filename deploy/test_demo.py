import copy
import os
import subprocess
import unittest
from unittest.mock import patch

import demo


IP = "192.0.2.10"
REVISION = "a" * 40
ENV = {"REVISION": REVISION, "DATABASE_PASSWORD": "b" * 64,
       "SECRET_KEY_BASE": "c" * 64, "REPOSITORY_URL": "https://github.com/example/demo.git",
       "DEMO_SSH_KEY_IDS": "123"}
VPC = {"id": "vpc-id", "name": demo.NAME, "region": "fra1"}
# Each test replaces demo.do with a fake; keep the real command wrapper for its own test.
DOCTL = demo.do


def api_error(code, message):
    # The text doctl reports for a failed API request.
    return RuntimeError('DELETE https://api.digitalocean.com/v2/resource: ' + str(code) +
                        ' (request "4f0c-409") ' + message)


def host(number, role):
    return {"id": number, "name": role + "-" + str(number), "tags": [demo.NAME, role],
            "vpc_uuid": "vpc-id", "region": {"slug": "fra1"},
            "networks": {"v4": [{"type": "private", "ip_address": "10.0.0." + str(number)},
                                  {"type": "public", "ip_address": "192.0.2." + str(number)}]}}


class DeploymentTest(unittest.TestCase):
    def setUp(self):
        self.database = host(10, demo.DB_TAG)
        self.app = host(20, demo.APP_TAG)
        self.candidate = host(30, demo.APP_TAG)
        self.reserved = {"ip": IP, "region": {"slug": "fra1"}, "droplet": {"id": 20}}
        self.droplets = [self.database, self.app]
        self.calls = []
        self.snapshots = [{"id": "snapshot-1", "resource_id": "10"},
                          {"id": "foreign-snapshot", "resource_id": "99"}]
        self.patches = [patch.dict(os.environ, ENV), patch.object(demo, "do", self.do),
                        patch.object(demo, "report"), patch.object(demo, "time")]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)

    def do(self, *args):
        self.calls.append(args)
        if args == ("compute", "ssh-key", "list"):
            return [{"id": 123}]
        if args == ("vpcs", "list"):
            return [VPC]
        if args == ("compute", "firewall", "list"):
            return [{"name": demo.DB_TAG, "id": "firewall-id"}]
        if args == ("compute", "droplet", "list"):
            return copy.deepcopy(self.droplets)
        if args == ("compute", "snapshot", "list"):
            return self.snapshots
        if args == ("compute", "reserved-ip", "list"):
            return []
        if args[:3] == ("compute", "reserved-ip-action", "unassign"):
            return [{"id": 456}]
        if args[:3] == ("compute", "action", "wait"):
            return [{"status": "completed"}]
        if args[:3] == ("compute", "snapshot", "delete"):
            self.snapshots = [s for s in self.snapshots if s["id"] != args[3]]
        if args[:3] == ("compute", "droplet", "delete"):
            self.droplets = [d for d in self.droplets if d["id"] != args[3]]
        return []

    def deploy(self):
        demo.deploy(IP, self.reserved, self.droplets)

    def settle(self, check, seconds, **kwargs):
        # Poll like wait_until, without sleeping.
        for _ in range(5):
            if check():
                return
        self.fail("Condition did not settle")

    def test_replaces_application_without_recreating_database_even_with_old_reset_flag(self):
        with patch.dict(os.environ, {"RECREATE": "true"}), \
             patch.object(demo, "create_host", return_value=self.candidate) as create, \
             patch.object(demo, "assign") as assign, \
             patch.object(demo, "wait_until") as wait:
            self.deploy()
        self.assertEqual(create.call_count, 1)
        self.assertEqual(create.call_args.args[1], demo.APP_TAG)
        self.assertEqual(create.call_args.args[5]["DATABASE_HOST"], "10.0.0.10")
        assign.assert_called_once_with(IP, 30)
        self.assertEqual(wait.call_count, 2)
        self.assertEqual(self.droplets, [self.database])

    def test_failed_candidate_keeps_old_application_and_database(self):
        with patch.object(demo, "create_host", return_value=self.candidate), \
             patch.object(demo, "wait_until", side_effect=RuntimeError("startup failed")), \
             patch.object(demo, "assign") as assign:
            with self.assertRaisesRegex(RuntimeError, "startup failed"):
                self.deploy()
        assign.assert_not_called()
        self.assertEqual(self.droplets, [self.database, self.app])
        self.assertIn(("compute", "droplet", "delete", 30, "--force"), self.calls)

    def test_first_deployment_creates_database_then_application(self):
        self.droplets = []
        self.reserved["droplet"] = None
        with patch.object(demo, "create_host", side_effect=[self.database, self.candidate]) as create, \
             patch.object(demo, "assign") as assign, patch.object(demo, "wait_until"):
            self.deploy()
        self.assertEqual([call.args[1] for call in create.call_args_list], [demo.DB_TAG, demo.APP_TAG])
        assign.assert_called_once_with(IP, 30)
        self.assertFalse(any("delete" in call for call in self.calls))

    def test_missing_secrets_stop_before_creating_resources(self):
        with patch.dict(os.environ, {"DATABASE_PASSWORD": ""}):
            with self.assertRaisesRegex(RuntimeError, "stable"):
                self.deploy()
        self.assertEqual(self.calls, [])

    def test_missing_ssh_key_configuration_stops_before_changes(self):
        with patch.dict(os.environ, {"DEMO_SSH_KEY_IDS": ""}):
            with self.assertRaisesRegex(RuntimeError, "SSH key IDs"):
                self.deploy()
        self.assertEqual(self.calls, [])

    def test_unknown_ssh_key_stops_before_changes(self):
        with patch.dict(os.environ, {"DEMO_SSH_KEY_IDS": "999"}):
            with self.assertRaisesRegex(RuntimeError, "missing from this DigitalOcean account"):
                self.deploy()
        self.assertEqual(self.calls, [("compute", "ssh-key", "list")])

    def test_both_host_roles_receive_the_configured_ssh_keys(self):
        for role in (demo.DB_TAG, demo.APP_TAG):
            with patch.object(demo, "do", side_effect=[[self.candidate], [self.candidate]]) as api:
                demo.create_host(role, role, "fra1", "vpc-id", "s-1vcpu-2gb", {})
            args = api.call_args_list[0].args
            self.assertEqual(args[args.index("--ssh-keys") + 1], "123")

    def test_database_firewall_allows_ssh_but_keeps_postgres_private(self):
        with patch.object(demo, "create_host", return_value=self.candidate), \
             patch.object(demo, "assign"), patch.object(demo, "wait_until"):
            self.deploy()
        call = next(c for c in self.calls if c[:3] == ("compute", "firewall", "update"))
        rules = call[call.index("--inbound-rules") + 1]
        self.assertIn("protocol:tcp,ports:22,address:0.0.0.0/0", rules)
        self.assertIn("protocol:tcp,ports:5432,tag:" + demo.APP_TAG, rules)
        self.assertNotIn("ports:5432,address:", rules)

    def test_failed_https_returns_ip_to_old_application(self):
        with patch.object(demo, "create_host", return_value=self.candidate), \
             patch.object(demo, "wait_until", side_effect=[None, RuntimeError("HTTPS failed")]), \
             patch.object(demo, "assign") as assign:
            with self.assertRaisesRegex(RuntimeError, "HTTPS failed"):
                self.deploy()
        self.assertEqual([c.args for c in assign.call_args_list], [(IP, 30), (IP, 20)])
        self.assertEqual(self.droplets, [self.database, self.app])

    def test_existing_single_server_stops_before_any_change(self):
        self.droplets[1]["name"] = demo.NAME
        with self.assertRaisesRegex(RuntimeError, "migrated first"):
            self.deploy()
        self.assertEqual(self.calls, [])

    def test_missing_database_is_not_replaced_by_empty_database(self):
        self.droplets = [self.app]
        with self.assertRaisesRegex(RuntimeError, "empty replacement"):
            self.deploy()
        self.assertEqual(self.calls, [])

    def test_database_cannot_be_deleted_as_application(self):
        for tags in ([demo.NAME, demo.DB_TAG], [demo.NAME, demo.APP_TAG, demo.DB_TAG], [demo.APP_TAG]):
            self.database["tags"] = tags
            with self.assertRaisesRegex(RuntimeError, "not an application"):
                demo.delete_application(self.database)
        self.assertEqual(self.calls, [])

    def test_foreign_ip_is_not_moved(self):
        self.reserved["droplet"]["id"] = 99
        with self.assertRaisesRegex(RuntimeError, "different host"):
            self.deploy()
        self.assertEqual(self.calls, [])

    def test_undeploy_removes_project_resources_only(self):
        foreign = host(99, "other-project")
        foreign["tags"] = []
        self.droplets.append(foreign)
        with patch.object(demo, "wait_until", side_effect=lambda check, seconds, **kwargs: self.assertTrue(check())):
            demo.undeploy(IP, self.reserved, self.droplets)
        self.assertEqual(self.droplets, [foreign])
        self.assertIn(("compute", "snapshot", "delete", "snapshot-1", "--force"), self.calls)
        self.assertNotIn(("compute", "snapshot", "delete", "foreign-snapshot", "--force"), self.calls)
        self.assertIn(("compute", "reserved-ip", "delete", IP, "--force"), self.calls)
        self.assertIn(("compute", "firewall", "delete", "firewall-id", "--force"), self.calls)
        self.assertIn(("vpcs", "delete", "vpc-id", "--force"), self.calls)

    def test_undeploy_refuses_foreign_ip_before_deleting_anything(self):
        self.reserved["droplet"]["id"] = 99
        with self.assertRaisesRegex(RuntimeError, "another project"):
            demo.undeploy(IP, self.reserved, self.droplets)
        self.assertEqual(self.calls, [])

    def test_release_retries_while_provider_finishes_unassignment(self):
        demo.time.monotonic.return_value = 0
        answers = [api_error(422, "The reserved IP is assigned"), None, []]
        with patch.object(demo, "do", side_effect=answers) as api, \
             patch.object(demo, "wait_until", side_effect=self.settle):
            demo.release_ip(IP)
        self.assertEqual(api.call_count, 3)

    def test_vpc_deletion_waits_for_deleted_servers_to_leave(self):
        demo.time.monotonic.return_value = 0
        original = self.do
        conflicts = [api_error(409, "Can not delete VPC with members")] * 2

        def api(*args):
            if args[:2] == ("vpcs", "delete") and conflicts:
                self.calls.append(args)
                raise conflicts.pop()
            return original(*args)

        with patch.object(demo, "do", side_effect=api), \
             patch.object(demo, "wait_until", side_effect=self.settle):
            demo.undeploy(IP, self.reserved, self.droplets)
        self.assertEqual(self.calls.count(("vpcs", "delete", "vpc-id", "--force")), 3)
        self.assertIn("DEMO_RESERVED_IP", demo.report.call_args.args[0])

    def test_removal_gives_up_with_the_provider_reason(self):
        demo.time.monotonic.side_effect = [0, 0, 301]
        with patch.object(demo, "do", side_effect=api_error(409, "Can not delete VPC with members")) as api:
            with self.assertRaisesRegex(RuntimeError, "Can not delete VPC with members.*after 300 seconds"):
                demo.remove("vpcs", "delete", "vpc-id")
        self.assertEqual(api.call_count, 2)

    def test_removal_does_not_retry_unexpected_failures(self):
        with patch.object(demo, "do", side_effect=api_error(403, "Forbidden")) as api:
            with self.assertRaisesRegex(RuntimeError, "Forbidden"):
                demo.remove("vpcs", "delete", "vpc-id")
        self.assertEqual(api.call_count, 1)

    def test_status_ignores_identifiers_that_look_like_codes(self):
        error = RuntimeError('DELETE https://api.digitalocean.com/v2/vpcs/409-404: 422 (request "404") Busy')
        self.assertEqual(demo.status(error), 422)
        self.assertIsNone(demo.status(RuntimeError("409 without request details")))

    def test_doctl_errors_are_reported_without_json_wrapping(self):
        stderr = ('{"errors":[{"detail":"DELETE https://api.digitalocean.com/v2/vpcs/vpc-id: 409 '
                  '(request \\"r-1\\") Can not delete VPC with members"}]}')
        failed = subprocess.CompletedProcess([], 1, stdout="", stderr=stderr)
        with patch.object(demo.subprocess, "run", return_value=failed):
            with self.assertRaises(RuntimeError) as raised:
                DOCTL("vpcs", "delete", "vpc-id", "--force")
        self.assertEqual(str(raised.exception),
                         'DELETE https://api.digitalocean.com/v2/vpcs/vpc-id: 409 (request "r-1") '
                         'Can not delete VPC with members')
        self.assertEqual(demo.status(raised.exception), 409)

    def test_undeploy_failure_lists_completed_removals_and_rerun(self):
        original = self.do

        def api(*args):
            if args[:2] == ("vpcs", "delete"):
                raise api_error(500, "Server Error")
            return original(*args)

        with patch.object(demo, "do", side_effect=api), \
             patch.object(demo, "wait_until", side_effect=self.settle):
            with self.assertRaises(RuntimeError) as raised:
                demo.undeploy(IP, self.reserved, self.droplets)
        message = str(raised.exception)
        self.assertIn("Server Error", message)
        self.assertIn("Already removed: 2 server(s), reserved IP " + IP + ", database firewall.", message)
        self.assertIn("Re-run Undeploy demonstration host", message)

    def test_missing_reserved_ip_explains_how_to_deploy_again(self):
        with self.assertRaisesRegex(RuntimeError, "set the DEMO_RESERVED_IP repository variable"):
            demo.deploy(IP, None, self.droplets)
        self.assertEqual(self.calls, [])

    def test_unassignment_failure_keeps_servers(self):
        original = self.do

        def api(*args):
            if args[:3] == ("compute", "action", "wait"):
                return [{"status": "errored"}]
            return original(*args)

        with patch.object(demo, "do", side_effect=api):
            with self.assertRaisesRegex(RuntimeError, "servers were retained"):
                demo.undeploy(IP, self.reserved, self.droplets)
        self.assertFalse(any("delete" in call for call in self.calls))

    def test_release_tolerates_a_stale_listing_after_deletion(self):
        answers = [None, [{"ip": IP}], []]
        with patch.object(demo, "do", side_effect=answers) as api, \
             patch.object(demo, "wait_until", side_effect=self.settle):
            demo.release_ip(IP)
        self.assertEqual(api.call_count, 3)

    def test_release_accepts_an_address_that_is_already_gone(self):
        answers = [api_error(404, "The resource you requested could not be found."), []]
        with patch.object(demo, "do", side_effect=answers) as api, \
             patch.object(demo, "wait_until", side_effect=self.settle):
            demo.release_ip(IP)
        self.assertEqual(api.call_count, 2)


if __name__ == "__main__":
    unittest.main()
