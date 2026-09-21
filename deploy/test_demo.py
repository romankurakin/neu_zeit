import copy
import os
import unittest
from unittest.mock import patch

import demo


IP = "192.0.2.10"
REVISION = "a" * 40
ENV = {"REVISION": REVISION, "DATABASE_PASSWORD": "b" * 64,
       "SECRET_KEY_BASE": "c" * 64, "REPOSITORY_URL": "https://github.com/example/demo.git"}
VPC = {"id": "vpc-id", "name": demo.NAME, "region": "fra1"}


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
        if args[:3] == ("compute", "snapshot", "delete"):
            self.snapshots = [s for s in self.snapshots if s["id"] != args[3]]
        if args[:3] == ("compute", "droplet", "delete"):
            self.droplets = [d for d in self.droplets if d["id"] != args[3]]
        return []

    def deploy(self):
        demo.deploy(IP, self.reserved, self.droplets)

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
        with patch.object(demo, "wait_until", side_effect=lambda check, seconds: self.assertTrue(check())):
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


if __name__ == "__main__":
    unittest.main()
