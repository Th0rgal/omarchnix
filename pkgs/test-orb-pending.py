"""Queue parsing and lock-gated dispatch regression tests."""
import importlib.util
import json
import os
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("sync", Path(__file__).with_name("orb-agent-sync.py"))
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class PendingTests(unittest.TestCase):
    def setUp(self):
        self.item = dict(kind="secret", id="request-1", tier="read", target="KEY",
                         risk="routine", reason="needed", digest="abc", request={})

    def test_queue_contract(self):
        self.assertEqual(sync.pending_items({"items": [self.item]})[0]["id"], "request-1")
        for invalid in ({}, {"items": None}, {"items": [self.item, self.item]},
                        {"items": [dict(self.item, digest=None)]},
                        {"items": [dict(self.item, kind="unknown")]}):
            with self.assertRaises(ValueError):
                sync.pending_items(invalid)

    def test_locked_never_queries_or_approves(self):
        with patch.object(sync, "approvals_unlocked", return_value=False), patch.object(sync, "locald_rpc") as rpc:
            self.assertEqual(sync.cmd_pending_update([]), 0)
            self.assertEqual(sync.cmd_pending_approve(["secret", "request-1", "abc"]), 1)
            rpc.assert_not_called()

    def test_changed_request_and_lock_during_read_refuse(self):
        for digest, states in (("old", [True, True]), ("abc", [True, False])):
            with patch.object(sync, "approvals_unlocked", side_effect=states), \
                 patch.object(sync, "locald_rpc", return_value={"items": [self.item]}) as rpc, \
                 patch.object(sync, "send_notification"):
                self.assertEqual(sync.cmd_pending_approve(["secret", "request-1", digest]), 1)
                rpc.assert_called_once_with("pending_requests_list", {})

    def test_approve_exact_contract_and_server_result(self):
        with patch.object(sync, "approvals_unlocked", return_value=True), \
             patch.object(sync, "locald_rpc", side_effect=[{"items": [self.item]}, {"state": "approved"}]) as rpc, \
             patch.object(sync, "cmd_pending_update"), patch("builtins.print") as output:
            self.assertEqual(sync.cmd_pending_approve(["secret", "request-1", "abc"]), 0)
            self.assertEqual(rpc.call_args.args, ("pending_requests_approve", {
                "kind": "secret", "id": "request-1", "expected_digest": "abc"}))
            self.assertEqual(json.loads(output.call_args.args[0]), {"state": "approved"})

    def test_failed_refresh_does_not_clear_queue(self):
        with patch.object(sync, "approvals_unlocked", return_value=True), \
             patch.object(sync, "locald_rpc", side_effect=RuntimeError()), patch.object(sync, "notification_rpc") as notify:
            self.assertEqual(sync.cmd_pending_update([]), 1)
            notify.assert_not_called()

    def test_scope_is_present_without_secret_contents(self):
        item = dict(self.item, request={"project_id": "source", "target_project_id": "dest",
                    "ttl_hours": 24, "all_projects": True, "value": "never-display"})
        detail = sync.pending_items({"items": [item]})[0]["detail"]
        for expected in ("project_id: source", "target_project_id: dest", "ttl_hours: 24", "all_projects: True"):
            self.assertIn(expected, detail)
        self.assertNotIn("never-display", detail)

    def test_core_bug_guards_keep_cards_but_refuse_dispatch(self):
        blocked = [dict(self.item, tier=tier) for tier in ("write", "delete", "move", "unknown")]
        for units in (["first", "second"], "first", None, {}, 1):
            blocked.append(dict(self.item, kind="privilege", request={"allowed_units": units}))
        for item in blocked:
            with self.subTest(item=item):
                projected = sync.pending_items({"items": [item]})
                self.assertEqual(len(projected), 1)
                self.assertFalse(projected[0]["canApprove"])
                if "allowed_units" in item["request"]:
                    self.assertIn("allowed_units: " + json.dumps(item["request"]["allowed_units"]), projected[0]["detail"])
                with patch.object(sync, "approvals_unlocked", return_value=True), \
                     patch.object(sync, "locald_rpc", return_value={"items": [item]}) as rpc, \
                     patch.object(sync, "send_notification"):
                    self.assertEqual(sync.cmd_pending_approve([item["kind"], item["id"], item["digest"]]), 1)
                    rpc.assert_called_once_with("pending_requests_list", {})
        for request in ({}, {"allowed_units": []}, {"allowed_units": ["single"]}):
            item = dict(self.item, kind="privilege", request=request)
            self.assertTrue(sync.pending_items({"items": [item]})[0]["canApprove"])

    def test_open_orb_is_lock_gated(self):
        with patch.object(sync, "approvals_unlocked", return_value=False), \
             patch.object(sync, "focus_or_spawn_orb") as launch:
            self.assertEqual(sync.main(["pending-open"]), 1)
            launch.assert_not_called()

    def test_locald_stale_digest_error_is_not_retried(self):
        with patch.object(sync, "approvals_unlocked", return_value=True), \
             patch.object(sync, "locald_rpc", side_effect=[{"items": [self.item]}, RuntimeError("stale digest")]) as rpc, \
             patch.object(sync, "send_notification"), patch("builtins.print") as output:
            self.assertEqual(sync.cmd_pending_approve(["secret", "request-1", "abc"]), 1)
            self.assertEqual(rpc.call_count, 2)
            output.assert_not_called()

    def test_http_rpc_wire_and_private_discovery(self):
        received = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                received.append((self.path, self.headers.get("X-Orb-Token"),
                                 json.loads(self.rfile.read(int(self.headers["Content-Length"])))))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"result":{"items":[]}}')

        with HTTPServer(("127.0.0.1", 0), Handler) as server, tempfile.TemporaryDirectory() as directory:
            thread = threading.Thread(target=server.serve_forever)
            thread.start()
            try:
                with patch.dict(os.environ, XDG_RUNTIME_DIR=directory):
                    path = Path(directory) / "orb-locald.json"
                    path.write_text(json.dumps({"port": server.server_port, "token": "x" * 32}))
                    path.chmod(0o644)
                    with self.assertRaises(RuntimeError):
                        sync.locald_rpc("pending_requests_list", {})
                    path.chmod(0o600)
                    self.assertEqual(sync.locald_rpc("pending_requests_list", {}), {"items": []})
                    path.unlink()
                    path.symlink_to("missing")
                    with self.assertRaises(OSError):
                        sync.locald_rpc("pending_requests_list", {})
            finally:
                server.shutdown()
                thread.join()
        self.assertEqual(received, [("/__orb_rpc", "x" * 32,
                                    {"command": "pending_requests_list", "args": {}})])


if __name__ == "__main__":
    unittest.main()
