"""Capture batch contracts over real loopback HTTP and temporary SQLite.

Run: python3 -B checks/CaptureBatchIngestionCheck.py
Only synthetic data; no Swift/UI, cloud, user DB, or production credentials.
This verifies server persistence/isolation, not the client's batchIDs routing.
"""
from collections import deque
import http.client
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))
import app


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class CaptureBatchIngestionCheck(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="capture-batch-check-")
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "synthetic.sqlite"
        self.store = app.Store(self.path)
        # Deliberately construct SQLite Store, never the environment-selected CLI store.
        self.token = self.store.create(dict(
            name="합성 배치 검사", memberName="합성 사용자", mode="separate"))["token"]
        self.server = app.make_server("127.0.0.1", 0, self.store)
        self.addCleanup(self.server.server_close)
        self.faults = deque()
        self.lost_response_id = None
        original = self.server.RequestHandlerClass
        probe = self

        class ControlledHandler(original):
            def do_POST(self):
                self.injected_fault = None
                if self.path == "/imports" and probe.faults:
                    self.injected_fault = probe.faults.popleft()
                    if self.injected_fault == "before_commit":
                        self.close_connection = True
                        self.respond(503, {"error": "synthetic pre-save failure"})
                        return
                super().do_POST()

            def respond(self, status, value):
                if (self.path == "/imports" and status == 200
                        and getattr(self, "injected_fault", None) == "after_commit"):
                    # Base handler reaches respond only after Store.run commits SQLite.
                    probe.lost_response_id = value["id"]
                    self.close_connection = True
                    return
                super().respond(status, value)

        self.server.RequestHandlerClass = ControlledHandler
        self.thread = threading.Thread(
            target=lambda: self.server.serve_forever(poll_interval=0.01), daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        # Ignore system proxies and reject redirects: every request stays on this server.
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        self.before = self.state()

    def stop_server(self):
        self.server.shutdown()
        self.thread.join(timeout=5)
        self.assertFalse(self.thread.is_alive())

    def tearDown(self):
        after = self.state()
        for key in ("entries", "stats", "personalStats", "settlement", "recurringPayments"):
            self.assertEqual(after[key], self.before[key],
                             f"Import/retry/exclusion must not change financial state: {key}")
        self.assertEqual(self.stored_entries(), [])
        self.assertFalse(self.faults, "Every requested fault must actually be exercised")

    def call(self, path, payload=None, *, method=None, token=None):
        if not path.startswith("/") or path.startswith("//") or "://" in path:
            raise ValueError("Only relative local API paths are allowed")
        # Match LedgerStore.mutate: even DELETE sends a JSON object.
        if payload is None and method == "DELETE":
            payload = {}
        request = urllib.request.Request(
            self.url + path,
            data=json.dumps(payload, ensure_ascii=False).encode() if payload is not None else None,
            headers={"Content-Type": "application/json", "Authorization": "Bearer " + (token or self.token)},
            method=method)
        try:
            with self.http.open(request, timeout=5) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            with error:
                return error.code, json.load(error)

    def state(self, token=None):
        status, result = self.call("/state?month=2026-10", token=token)
        self.assertEqual(status, 200)
        return result

    def stored(self, key):
        # Reopen the file to verify durable state rather than a handler's response object.
        return app.Store(self.path).run(self.token, lambda state, actor: state[key])

    def stored_entries(self):
        return self.stored("entries")

    @staticmethod
    def payload(event, amount=1000, merchant="합성상점", reference=None):
        raw = f"카드 1234 승인 {amount:,}원\n가맹점: {merchant}\n2026/10/27 10:00"
        if reference is not None:
            raw += "\n승인번호 " + reference
        return dict(text=raw, source="paste", eventID=event)

    def submit(self, payload, *, token=None):
        status, result = self.call("/imports", payload, token=token)
        self.assertEqual(status, 200)
        return result

    def assert_pending_ids(self, expected):
        inbox = self.state()["inbox"]
        self.assertEqual({row["id"] for row in inbox}, set(expected))
        self.assertEqual(len(inbox), len(expected))
        self.assertTrue(all(row["status"] == "pending" for row in inbox))

    def test_batch_retry_keeps_ids_and_different_amounts(self):
        payloads = [self.payload(f"amount-{i}", amount) for i, amount in enumerate((1100, 2200, 3300))]
        first = [self.submit(p) for p in payloads]
        retry = [self.submit(p) for p in reversed(payloads)]
        self.assertEqual([r["id"] for r in retry], [r["id"] for r in reversed(first)])
        self.assertEqual([r["amount"] for r in first], [1100, 2200, 3300])
        self.assertTrue(all(not r["candidates"] for r in first))
        self.assert_pending_ids([r["id"] for r in first])
        self.assertEqual(len(self.stored("imports")), 3)

    def test_same_amount_different_merchants_stay_separate(self):
        first = self.submit(self.payload("shop-a", 4500, "합성가게가"))
        second = self.submit(self.payload("shop-b", 4500, "합성가게나"))
        self.assertNotEqual(first["id"], second["id"])
        self.assertEqual([first["merchant"], second["merchant"]], ["합성가게가", "합성가게나"])
        self.assertEqual((first["candidates"], second["candidates"]), ([], []))
        self.assert_pending_ids([first["id"], second["id"]])

    def test_identical_raw_same_event_replays_one_pending(self):
        payload = self.payload("same-event")
        first = self.submit(payload)
        for _ in range(3):
            self.assertEqual(self.submit(payload), first)
        self.assert_pending_ids([first["id"]])
        self.assertEqual(self.stored("imports")[0]["events"], ["paste:same-event"])

    def test_identical_raw_different_events_keep_duplicate_comparison(self):
        payload = self.payload("raw-a")
        first = self.submit(payload)
        second_payload = {**payload, "eventID": "raw-b"}
        second = self.submit(second_payload)
        self.assertNotEqual(first["id"], second["id"])
        self.assertEqual(second["raw"], first["raw"])
        self.assertEqual(second["candidates"], [first["id"]])
        self.assertEqual(self.submit(second_payload)["id"], second["id"])
        self.assert_pending_ids([first["id"], second["id"]])

    def test_same_reference_can_share_response_id_across_events(self):
        payload = self.payload("reference-a", reference="SYNTH1234")
        first = self.submit(payload)
        second = self.submit({**payload, "eventID": "reference-b"})
        self.assertEqual(second["id"], first["id"])
        self.assertEqual(self.submit(payload)["id"], first["id"])
        self.assertEqual(self.stored("imports")[0]["events"], ["paste:reference-a", "paste:reference-b"])
        self.assert_pending_ids([first["id"]])

    def test_partial_precommit_failure_retries_successes_without_duplication(self):
        payloads = [self.payload(f"partial-{i}", amount) for i, amount in enumerate((5100, 6200, 7300))]
        first = self.submit(payloads[0])
        self.faults.append("before_commit")
        self.assertEqual(self.call("/imports", payloads[1])[0], 503)
        self.assert_pending_ids([first["id"]])
        self.assertEqual(len(self.stored("imports")), 1)
        third = self.submit(payloads[2])
        retry = [self.submit(p) for p in payloads]
        self.assertEqual(retry[0]["id"], first["id"])
        self.assertEqual(retry[2]["id"], third["id"])
        self.assertEqual([r["amount"] for r in retry], [5100, 6200, 7300])
        self.assert_pending_ids([r["id"] for r in retry])
        self.assertEqual(len(self.stored("imports")), 3)

    def test_lost_postcommit_response_replays_the_committed_id(self):
        first_payload = self.payload("loss-a", 8100)
        lost_payload = self.payload("loss-b", 9200)
        first = self.submit(first_payload)
        self.faults.append("after_commit")
        with self.assertRaises(http.client.RemoteDisconnected):
            self.call("/imports", lost_payload)
        self.assertIsNotNone(self.lost_response_id)
        self.assert_pending_ids([first["id"], self.lost_response_id])
        self.assertEqual(len(self.stored("imports")), 2)
        self.assertEqual(self.submit(first_payload)["id"], first["id"])
        recovered = self.submit(lost_payload)
        self.assertEqual((recovered["id"], recovered["amount"]), (self.lost_response_id, 9200))
        self.assertEqual(len(self.stored("imports")), 2)

    def test_existing_pending_outside_batch_survives_import_retry_and_exclusion(self):
        outside = self.submit(self.payload("outside", 9900, "기존합성상점"))
        before_row = next(r for r in self.state()["inbox"] if r["id"] == outside["id"])
        payloads = [self.payload("batch-a", 1200), self.payload("batch-b", 3400)]
        batch = [self.submit(p) for p in payloads]
        for payload, result in zip(payloads, batch):
            self.assertEqual(self.submit(payload)["id"], result["id"])
        # /state has no batch filter: the client must select its ordered response IDs.
        self.assert_pending_ids([outside["id"], *(r["id"] for r in batch)])
        for result in batch:
            self.assertEqual(self.call("/imports/" + result["id"], method="DELETE")[0], 200)
        self.assertEqual(self.state()["inbox"], [before_row])
        self.assertEqual(next(r for r in self.stored("imports") if r["id"] == outside["id"])["status"], "pending")

    def test_reused_event_does_not_update_payload_and_source_is_part_of_key(self):
        original = self.submit(self.payload("frozen", 1500))
        changed = self.submit(self.payload("frozen", 9500, "다른합성상점"))
        self.assertEqual((changed["id"], changed["amount"], changed["merchant"]),
                         (original["id"], 1500, "합성상점"))
        other_source = self.submit({**self.payload("frozen", 1500), "source": "app"})
        self.assertNotEqual(other_source["id"], original["id"])
        self.assert_pending_ids([original["id"], other_source["id"]])

    def test_retry_after_exclusion_does_not_resurrect_pending(self):
        payload = self.payload("excluded")
        first = self.submit(payload)
        self.assertEqual(self.call("/imports/" + first["id"], method="DELETE")[0], 200)
        replay = self.submit(payload)
        self.assertEqual((replay["id"], replay["status"]), (first["id"], "ignored"))
        self.assert_pending_ids([])
        self.assertEqual(len(self.stored("imports")), 1)

    def test_same_event_and_raw_are_isolated_between_members(self):
        invitation = self.store.invite(self.token)
        partner = self.store.join(dict(invite=invitation["invite"], memberName="합성 상대"))["token"]
        self.before = self.state()  # Membership setup is not an import side effect.
        payload = self.payload("same-member-event")
        first = self.submit(payload)
        second = self.submit(payload, token=partner)
        self.assertNotEqual(first["id"], second["id"])
        self.assert_pending_ids([first["id"]])
        self.assertEqual([r["id"] for r in self.state(partner)["inbox"]], [second["id"]])
        status, error = self.call("/imports/" + first["id"], method="DELETE", token=partner)
        self.assertEqual(status, 400)
        self.assertEqual(error["error"], "확인할 알림을 찾을 수 없어요.")
        self.assert_pending_ids([first["id"]])

    def test_unresolved_content_remains_pending_instead_of_being_dropped(self):
        raw = "합성 캡처 미확인 내용\n거래금액 또는 상호 확인 필요"
        payload = dict(text=raw, source="paste", eventID="unresolved")
        result = self.submit(payload)
        self.assertEqual((result["status"], result["kind"], result["amount"]), ("pending", "unknown", None))
        self.assertTrue(result["requiresReview"])
        self.assertEqual(result["raw"], raw)
        self.assertEqual(self.submit(payload)["id"], result["id"])
        self.assert_pending_ids([result["id"]])


if __name__ == "__main__":
    unittest.main(verbosity=2)
