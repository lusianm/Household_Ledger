import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "ledger_connect", Path(__file__).resolve().parents[1] / "scripts/ledger-connect.py"
)
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)


class ConnectionClientTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.data = {
            "ledger": "ledger", "connection": "session",
            "entries": [{"data": {"id": "entry"}, "base": "version", "editable": True}],
        }
        self.plan = {
            "ledger": "ledger", "connection": "session",
            "operations": [{"id": "entry", "base": "version", "set": {"category": "식비"}}],
        }

    def test_publish_and_acknowledge(self):
        request = client.publish(self.folder, self.data, self.plan)
        self.assertEqual(client.read_json(self.folder / "request.json"), request)
        self.assertEqual(list(self.folder.glob("*.tmp")), [])
        self.assertIsNone(client.result_for(self.folder, request))
        result = {**request, "format": "chagok-file-result", "status": "applied"}
        (self.folder / "result.json").write_text(json.dumps(result), encoding="utf-8")
        self.assertEqual(client.result_for(self.folder, request)["status"], "applied")
        next_request = client.publish(self.folder, self.data, self.plan)
        self.assertNotEqual(request["id"], next_request["id"])
        self.assertIsNone(client.result_for(self.folder, next_request))

    def test_pending_request_is_not_overwritten(self):
        request = client.publish(self.folder, self.data, self.plan)
        with self.assertRaisesRegex(ValueError, "이전 요청"):
            client.publish(self.folder, self.data, self.plan)
        self.assertEqual(client.read_json(self.folder / "request.json"), request)

    def test_old_session_request_does_not_block_new_connection(self):
        client.publish(self.folder, self.data, self.plan)
        self.data["connection"] = self.plan["connection"] = "new-session"
        self.assertEqual(client.publish(self.folder, self.data, self.plan)["connection"], "new-session")

    def test_stale_or_duplicate_plan_never_writes(self):
        self.plan["operations"][0]["base"] = "old"
        with self.assertRaises(ValueError):
            client.publish(self.folder, self.data, self.plan)
        self.plan["operations"][0]["base"] = "version"
        self.plan["operations"].append(self.plan["operations"][0])
        with self.assertRaises(ValueError):
            client.publish(self.folder, self.data, self.plan)
        self.assertFalse((self.folder / "request.json").exists())

    def test_result_from_other_connection_is_not_success(self):
        request = client.publish(self.folder, self.data, self.plan)
        result = {**request, "format": "chagok-file-result", "connection": "other", "status": "applied"}
        (self.folder / "result.json").write_text(json.dumps(result), encoding="utf-8")
        self.assertIsNone(client.result_for(self.folder, request))


if __name__ == "__main__":
    unittest.main()
