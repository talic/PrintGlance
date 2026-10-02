"""Tests for the Python feed (bambu.py, print_loop.py). Stdlib unittest only.

Run from the repo root:
    .venv/bin/python -m unittest discover -s Tests/Feed -v
"""

from __future__ import annotations

import contextlib
import http.client
import io
import json
import os
import re
import socket
import socketserver
import sys
import threading
import time
import unittest
from datetime import datetime, timezone
from http.server import ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import bambu  # noqa: E402
import print_loop  # noqa: E402

SERIAL = "0309CAFEXJQZK7W"
ACCESS_CODE = "48151623"
PRINTER_IP = "192.0.2.77"
ENV = {"BAMBU_IP": PRINTER_IP, "BAMBU_SERIAL": SERIAL, "BAMBU_ACCESS_CODE": ACCESS_CODE}
PUSHALL = {"pushing": {"command": "pushall", "sequence_id": "0"}}


def ams_unit(unit_id: int, *types: str) -> dict:
    trays = [{"id": str(i), "tray_type": t, "remain": 50} for i, t in enumerate(types)]
    return {"id": str(unit_id), "tray": trays}


def snapshot(print_obj: dict | None = None, name: str = "X2D") -> bambu.BambuSnapshot:
    snap = bambu.BambuSnapshot("x2d", name)
    if print_obj:
        snap.ingest({"print": print_obj})
    return snap


def message(payload: bytes) -> SimpleNamespace:
    return SimpleNamespace(payload=payload)


class MergePrintTests(unittest.TestCase):
    def test_keeps_missing_keys(self):
        dst = {"gcode_state": "RUNNING", "mc_percent": 40}
        bambu.merge_print(dst, {"mc_percent": 41})
        self.assertEqual(dst, {"gcode_state": "RUNNING", "mc_percent": 41})

    def test_empty_incoming_is_noop(self):
        dst = {"task_id": "1", "layer_num": 5}
        bambu.merge_print(dst, {})
        self.assertEqual(dst, {"task_id": "1", "layer_num": 5})

    def test_job_change_drops_layer_and_gcode(self):
        for key in ("task_id", "subtask_id", "subtask_name"):
            with self.subTest(key=key):
                dst = {
                    key: "old",
                    "layer_num": 90,
                    "total_layer_num": 100,
                    "gcode_file": "old.gcode",
                    "mc_percent": 90,
                }
                bambu.merge_print(dst, {key: "new"})
                self.assertEqual(dst, {key: "new", "mc_percent": 90})

    def test_job_change_keeps_incoming_layer(self):
        """The delta that announces a new job often carries its first layer."""
        dst = {"task_id": "1", "layer_num": 90}
        bambu.merge_print(dst, {"task_id": "2", "layer_num": 1})
        self.assertEqual(dst, {"task_id": "2", "layer_num": 1})

    def test_empty_or_same_id_is_not_a_job_change(self):
        for old, new in (("", "7"), (None, "7"), ("7", ""), ("7", None), ("7", "7")):
            with self.subTest(old=old, new=new):
                dst = {"task_id": old, "layer_num": 90, "total_layer_num": 100, "gcode_file": "a.gcode"}
                bambu.merge_print(dst, {"task_id": new})
                self.assertEqual(
                    (dst["layer_num"], dst["total_layer_num"], dst["gcode_file"]),
                    (90, 100, "a.gcode"),
                )


class JobLabelTests(unittest.TestCase):
    def test_cache_paths_rejected(self):
        for path in ("cache/abc.gcode", "/sdcard/cache/Benchy.gcode", "CACHE/Benchy.gcode", "sd\\cache\\Benchy.gcode"):
            with self.subTest(path=path):
                self.assertIsNone(bambu.human_gcode_stem(path))

    def test_hex_and_numeric_stems_rejected(self):
        for path in ("deadbeef.gcode", "0123456789abcdef.3mf", "123456.gcode", "20261002.gco"):
            with self.subTest(path=path):
                self.assertIsNone(bambu.human_gcode_stem(path))
        self.assertEqual(bambu.human_gcode_stem("deadbee.gcode"), "deadbee")
        self.assertEqual(bambu.human_gcode_stem("12345.gcode"), "12345")

    def test_backslashes_are_path_separators(self):
        self.assertEqual(bambu.human_gcode_stem("C:\\Users\\me\\Benchy.gcode"), "Benchy")

    def test_strips_known_extension(self):
        cases = {
            "models/Benchy.gcode": "Benchy",
            "Benchy.3MF": "Benchy",
            "Benchy.gco": "Benchy",
            "Benchy.stl": "Benchy.stl",
            "  models/Benchy.gcode  ": "Benchy",
            "/sdcard/Benchy.gcode.3mf": "Benchy",
        }
        for path, want in cases.items():
            with self.subTest(path=path):
                self.assertEqual(bambu.human_gcode_stem(path), want)

    def test_short_blank_or_non_string_rejected(self):
        for value in ("", "   ", "a.gcode", "models/", None, 42, ["Benchy.gcode"], {"f": "Benchy.gcode"}):
            with self.subTest(value=value):
                self.assertIsNone(bambu.human_gcode_stem(value))

    def test_strip_process_suffix(self):
        cases = {
            "Print in Parts 0.16mm layer, 2 walls, 10% infill": "Print in Parts",
            "Benchy 0.2MM": "Benchy",
            "Benchy  0.08mm layer": "Benchy",
            "Benchy": "Benchy",
            "Benchy_0.2mm": "Benchy_0.2mm",
            "Benchy .08mm": "Benchy",
            "Spacer 20mm x4": "Spacer 20mm x4",
            "Cable clip 1.5mm": "Cable clip 1.5mm",
            "Spacer 20mm 0.2mm layer, 2 walls": "Spacer 20mm",
        }
        for raw, want in cases.items():
            with self.subTest(raw=raw):
                self.assertEqual(bambu.strip_process_suffix(raw), want)

    def test_job_label_prefers_gcode_stem(self):
        self.assertEqual(
            bambu.job_label({"gcode_file": "models/Benchy.gcode", "subtask_name": "Other 0.2mm"}),
            "Benchy",
        )

    def test_job_label_falls_back_to_subtask_name(self):
        self.assertEqual(
            bambu.job_label({"gcode_file": "cache/abc.gcode", "subtask_name": "Benchy 0.2mm layer"}),
            "Benchy",
        )

    def test_job_label_keeps_raw_when_suffix_is_everything(self):
        self.assertEqual(bambu.job_label({"subtask_name": " 0.2mm layer "}), "0.2mm layer")

    def test_job_label_truncates_to_40(self):
        self.assertEqual(bambu.job_label({"subtask_name": "x" * 40}), "x" * 40)
        self.assertEqual(bambu.job_label({"subtask_name": "x" * 41}), "x" * 37 + "...")
        self.assertEqual(bambu.job_label({"gcode_file": "y" * 50 + ".gcode"}), "y" * 37 + "...")

    def test_job_label_non_string_or_missing_is_none(self):
        for obj in ({}, {"subtask_name": 7}, {"subtask_name": "   "}, {"gcode_file": 7, "subtask_name": None}):
            with self.subTest(obj=obj):
                self.assertIsNone(bambu.job_label(obj))


class ActiveFilamentTests(unittest.TestCase):
    def test_tray_now_selects_tray(self):
        ams = {"tray_now": "1", "ams": [ams_unit(0, "ABS", "PLA")]}
        self.assertEqual(bambu.active_filament({"ams": ams}), ("PLA", 50))

    def test_falls_back_to_tray_tar(self):
        for ams in (
            {"tray_tar": "1", "ams": [ams_unit(0, "ABS", "PLA")]},
            {"tray_now": "", "tray_tar": 1, "ams": [ams_unit(0, "ABS", "PLA")]},
        ):
            with self.subTest(ams=ams):
                self.assertEqual(bambu.active_filament({"ams": ams}), ("PLA", 50))

    def test_255_means_no_filament(self):
        for now in (255, "255"):
            with self.subTest(now=now):
                ams = {"tray_now": now, "ams": [ams_unit(0, "PLA")]}
                self.assertEqual(bambu.active_filament({"ams": ams}), (None, None))

    def test_254_reads_external_spool(self):
        ams = {"tray_now": 254, "ams": [ams_unit(0, "PLA")]}
        self.assertEqual(
            bambu.active_filament({"ams": ams, "vt_tray": {"tray_type": "PETG", "remain": 80}}),
            ("PETG", 80),
        )
        self.assertEqual(bambu.active_filament({"ams": ams}), (None, None))
        self.assertEqual(bambu.active_filament({"ams": ams, "vt_tray": "PETG"}), (None, None))

    def test_negative_remain_is_none(self):
        vt = {"tray_type": "PLA", "remain": -1}
        self.assertEqual(bambu.active_filament({"ams": {"tray_now": 254}, "vt_tray": vt}), ("PLA", None))

    def test_remain_clamped_to_100(self):
        vt = {"tray_type": "PLA", "remain": 140}
        self.assertEqual(bambu.active_filament({"ams": {"tray_now": 254}, "vt_tray": vt}), ("PLA", 100))

    def test_type_stripped_and_truncated_to_8(self):
        cases = [
            ({"tray_type": "  PLA-CF Support  "}, "PLA-CF S"),
            ({"tray_type": "", "type": "TPU"}, "TPU"),
            ({"tray_type": "   "}, None),
            ({"tray_type": 5}, None),
        ]
        for vt, want in cases:
            with self.subTest(vt=vt):
                self.assertEqual(bambu.active_filament({"ams": {"tray_now": 254}, "vt_tray": vt})[0], want)

    def test_missing_tray_is_none(self):
        ams = {"tray_now": 3, "ams": [ams_unit(0, "PLA")]}
        self.assertEqual(bambu.active_filament({"ams": ams}), (None, None))

    def test_garbage_shapes_do_not_raise(self):
        objs = [
            {"ams": "x"},
            {"ams": []},
            {"ams": {"tray_now": "abc"}},
            {"ams": {"tray_now": 0, "ams": "x"}},
            {"ams": {"tray_now": 0, "ams": ["x", {"tray": {"id": "0"}}]}},
            {"ams": {"tray_now": 0, "ams": [{"tray": ["x", 3, None]}]}},
            {"ams": {"tray_now": 0, "ams": [{"tray": [{"id": "zero", "tray_type": "PLA"}]}]}},
        ]
        for obj in objs:
            with self.subTest(obj=obj):
                self.assertEqual(bambu.active_filament(obj), (None, None))

    def test_tray_now_is_global_across_ams_units(self):
        """tray_now counts across units: AMS B slot 2 is 5. Same mapping as the app."""
        ams = {"tray_now": 5, "ams": [ams_unit(0, "PLA", "PLA", "PLA", "PLA"), ams_unit(1, "ABS", "PETG", "ASA", "TPU")]}
        self.assertEqual(bambu.active_filament({"ams": ams}), ("PETG", 50))
        ams["tray_now"] = 1
        self.assertEqual(bambu.active_filament({"ams": ams}), ("PLA", 50))

    def test_units_without_ids_count_by_position(self):
        ams = {"tray_now": 6, "ams": [{"tray": [{"id": "2", "tray_type": "PLA"}]}, {"tray": [{"id": "2", "tray_type": "ASA"}]}]}
        self.assertEqual(bambu.active_filament({"ams": ams})[0], "ASA")


class PrinterRowTests(unittest.TestCase):
    def row(self, print_obj: dict, online: bool = True) -> dict:
        return bambu.printer_row("x2d", "X2D", print_obj, online=online)

    def test_offline_when_not_online(self):
        row = self.row({"gcode_state": "RUNNING", "mc_percent": 62}, online=False)
        self.assertEqual((row["state"], row["percent"]), ("OFFLINE", 62))

    def test_offline_when_state_empty(self):
        for obj in ({}, {"gcode_state": ""}, {"gcode_state": None}):
            with self.subTest(obj=obj):
                self.assertEqual(self.row(obj)["state"], "OFFLINE")

    def test_state_uppercased_and_unknown_passed_through(self):
        self.assertEqual(self.row({"gcode_state": "running"})["state"], "RUNNING")
        self.assertEqual(self.row({"gcode_state": "SLICING"})["state"], "SLICING")

    def test_percent_clamped(self):
        for raw, want in ((150, 100), (-5, 0), ("42", 42), (0, 0)):
            with self.subTest(raw=raw):
                self.assertEqual(self.row({"gcode_state": "RUNNING", "mc_percent": raw})["percent"], want)

    def test_remaining_minutes_to_seconds(self):
        for raw, want in ((2, 120), ("5", 300), (-3, 0), (0, 0)):
            with self.subTest(raw=raw):
                self.assertEqual(self.row({"gcode_state": "RUNNING", "mc_remaining_time": raw})["remaining_s"], want)

    def test_infinite_and_huge_numbers_are_none_or_capped(self):
        """json.loads turns Infinity and 1e999 into float('inf'); int() of that raises OverflowError."""
        report = json.loads(
            '{"gcode_state":"RUNNING","mc_percent":Infinity,"mc_remaining_time":1e999,"layer_num":-Infinity,'
            '"total_layer_num":NaN,"ams":{"tray_now":Infinity,"ams":[{"id":"0","tray":[{"id":"0","remain":1e999}]}]}}'
        )
        row = self.row(report)
        self.assertEqual((row["percent"], row["remaining_s"], row["layer"], row["layer_total"]), (None, None, None, None))
        huge = self.row({"gcode_state": "RUNNING", "mc_remaining_time": 10**30})
        self.assertEqual(huge["remaining_s"], bambu.MAX_REMAINING_MIN * 60, "30 days, like the app")
        self.assertRegex(huge["eta"], r"^\d{2}:\d{2}$")

    def test_hostile_report_still_serves_json(self):
        snap = snapshot()
        bambu._on_message_v2(None, {"snap": snap, "serial": SERIAL}, message(b'{"print":{"gcode_state":"RUNNING","mc_percent":1e999}}'))
        self.assertEqual(json.loads(snap.print_json_bytes())["printers"][0]["state"], "RUNNING")

    def test_non_numeric_fields_are_none(self):
        row = self.row({
            "gcode_state": "RUNNING",
            "mc_percent": "abc",
            "mc_remaining_time": [1],
            "layer_num": "x",
            "total_layer_num": {},
        })
        self.assertEqual(
            (row["percent"], row["remaining_s"], row["layer"], row["layer_total"], row["eta"]),
            (None, None, None, None, None),
        )

    def test_layer_only_when_key_present(self):
        row = self.row({"gcode_state": "RUNNING"})
        self.assertEqual((row["layer"], row["layer_total"]), (None, None))
        row = self.row({"gcode_state": "RUNNING", "layer_num": 0, "total_layer_num": "120"})
        self.assertEqual((row["layer"], row["layer_total"]), (0, 120))

    def test_eta_only_while_printing(self):
        """eta_hm uses local time, so only the HH:MM format is checked."""
        for state in ("RUNNING", "PREPARE", "PAUSE"):
            with self.subTest(state=state):
                eta = self.row({"gcode_state": state, "mc_remaining_time": 5})["eta"]
                self.assertRegex(eta, r"^\d{2}:\d{2}$")
        for state in ("FINISH", "IDLE", "FAILED"):
            with self.subTest(state=state):
                self.assertIsNone(self.row({"gcode_state": state, "mc_remaining_time": 5})["eta"])
        self.assertIsNone(self.row({"gcode_state": "RUNNING", "mc_remaining_time": 0})["eta"])
        self.assertIsNone(self.row({"gcode_state": "RUNNING", "mc_remaining_time": 5}, online=False)["eta"])


class FocusAndDocTests(unittest.TestCase):
    def test_pick_focus_order(self):
        cases = [
            (["RUNNING", "PREPARE"], "p1"),
            (["IDLE", "PAUSE", "RUNNING"], "p2"),
            (["IDLE", "PAUSE"], "p1"),
            (["OFFLINE", "FINISH", "IDLE"], "p1"),
            (["OFFLINE", "OFFLINE"], "p0"),
            (["offline", "running"], "p1"),
            ([], None),
        ]
        for states, want in cases:
            with self.subTest(states=states):
                printers = [{"id": f"p{i}", "state": s} for i, s in enumerate(states)]
                self.assertEqual(bambu.pick_focus_id(printers), want)

    def test_build_doc_shape(self):
        doc = bambu.build_doc("x2d", "X2D", {"gcode_state": "IDLE"}, online=True, updated_at="2026-01-02T03:04:05Z")
        self.assertEqual(set(doc), {"v", "updated_at", "focus_id", "printers"})
        self.assertEqual((doc["v"], doc["updated_at"], doc["focus_id"]), (1, "2026-01-02T03:04:05Z", "x2d"))
        self.assertEqual(len(doc["printers"]), 1)
        self.assertEqual(
            set(doc["printers"][0]),
            {"id", "name", "state", "percent", "remaining_s", "job", "layer", "layer_total", "eta",
             "filament", "filament_remain"},
        )


class SnapshotTests(unittest.TestCase):
    def test_offline_before_any_report(self):
        snap = snapshot()
        snap.mark_connected(True)
        self.assertFalse(snap.online())
        doc = snap.document()
        self.assertEqual((doc["updated_at"], doc["printers"][0]["state"]), (None, "OFFLINE"))

    def test_online_after_ingest(self):
        snap = snapshot({"gcode_state": "RUNNING"})
        self.assertTrue(snap.online())
        self.assertEqual(snap.document()["printers"][0]["state"], "RUNNING")

    def test_offline_after_stale(self):
        snap = snapshot({"gcode_state": "RUNNING"})
        snap._last_report = time.monotonic() - (bambu.STALE_AFTER_S + 1)
        self.assertFalse(snap.online())

    def test_mark_connected_false_makes_offline(self):
        snap = snapshot({"gcode_state": "RUNNING"})
        snap.mark_connected(False)
        self.assertFalse(snap.online())

    def test_ingest_ignores_non_dict_or_empty_print(self):
        snap = snapshot()
        for payload in ({}, {"print": {}}, {"print": []}, {"print": "RUNNING"}, {"print": None}, {"info": {"a": 1}}):
            snap.ingest(payload)
        self.assertFalse(snap.online())
        self.assertIsNone(snap.last_report_iso())
        self.assertEqual(snap.copy_print(), {})

    def test_print_json_bytes_cached_until_gen_or_online_changes(self):
        snap = snapshot({"gcode_state": "RUNNING", "mc_percent": 16})
        b1 = snap.print_json_bytes()
        self.assertIs(snap.print_json_bytes(), b1)

        snap.ingest({"print": {"mc_percent": 17}})
        b2 = snap.print_json_bytes()
        self.assertIsNot(b2, b1)
        self.assertEqual(json.loads(b2)["printers"][0]["percent"], 17)
        self.assertIs(snap.print_json_bytes(), b2)

        snap._last_report = time.monotonic() - (bambu.STALE_AFTER_S + 1)
        b3 = snap.print_json_bytes()
        self.assertEqual(json.loads(b3)["printers"][0]["state"], "OFFLINE")
        self.assertIs(snap.print_json_bytes(), b3)

        snap.ingest({"print": {"mc_percent": 18}})
        snap.mark_connected(False)
        self.assertEqual(json.loads(snap.print_json_bytes())["printers"][0]["state"], "OFFLINE")

    def test_updated_at_is_utc_iso(self):
        iso = snapshot({"gcode_state": "IDLE"}).document()["updated_at"]
        self.assertRegex(iso, r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
        stamped = datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        self.assertLess(abs((datetime.now(timezone.utc) - stamped).total_seconds()), 120)

    def test_concurrent_ingest_and_reads(self):
        snap = snapshot()
        errors: list[BaseException] = []
        start = threading.Barrier(8, timeout=10)

        def guard(fn, *args):
            try:
                start.wait()
                fn(*args)
            except BaseException as e:  # noqa: BLE001
                errors.append(e)

        def writer(n: int) -> None:
            for i in range(300):
                snap.ingest({"print": {"gcode_state": "RUNNING", "mc_percent": i % 101, "task_id": str(n)}})

        def reader() -> None:
            for _ in range(300):
                json.loads(snap.print_json_bytes())
                snap.document()

        threads = [threading.Thread(target=guard, args=(writer, n)) for n in range(4)]
        threads += [threading.Thread(target=guard, args=(reader,)) for _ in range(4)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(30)
        self.assertEqual(errors, [])
        # The cache must never hold a body built from an older generation.
        fresh = json.dumps(snap.document(), separators=(",", ":")).encode("utf-8")
        self.assertEqual(snap.print_json_bytes(), fresh)


class FakeClient:
    """Only subscribe/publish exist, so any other client call fails the test."""

    def __init__(self) -> None:
        self.subscribed: list = []
        self.published: list = []

    def subscribe(self, topic, qos=0):
        self.subscribed.append((topic, qos))

    def publish(self, topic, payload=None, qos=0):
        self.published.append((topic, payload, qos))


class MqttCallbackTests(unittest.TestCase):
    def test_connect_subscribes_report_and_requests_pushall_only(self):
        """The feed is read-only: one report subscription and one pushall, nothing else."""
        for rc in (SimpleNamespace(is_failure=False), 0, "Success"):
            with self.subTest(rc=rc):
                client = FakeClient()
                bambu._on_connect_v2(client, {"snap": snapshot(), "serial": SERIAL}, {}, rc, None)
                self.assertEqual(client.subscribed, [(f"device/{SERIAL}/report", 0)])
                self.assertEqual(len(client.published), 1)
                topic, payload, _ = client.published[0]
                self.assertEqual(topic, f"device/{SERIAL}/request")
                self.assertEqual(json.loads(payload), PUSHALL)

    def test_connect_failure_publishes_nothing_and_marks_offline(self):
        for rc in (SimpleNamespace(is_failure=True), 5, "Not authorized"):
            with self.subTest(rc=rc):
                snap = snapshot({"gcode_state": "RUNNING"})
                client = FakeClient()
                with self.assertLogs("bambu", "WARNING"):
                    bambu._on_connect_v2(client, {"snap": snap, "serial": SERIAL}, {}, rc, None)
                self.assertEqual((client.subscribed, client.published), ([], []))
                self.assertFalse(snap.online())

    def test_message_ignores_bad_payloads(self):
        snap = snapshot()
        payloads = {p.decode("latin-1"): p for p in (b"\xff\xfe\x00", b"{not json", b"[1, 2]", b'"RUNNING"', b"null", b"42")}
        payloads["100k nested arrays"] = b"[" * 100_000 + b"]" * 100_000  # RecursionError in json.loads
        for label, payload in payloads.items():
            with self.subTest(payload=label):
                bambu._on_message_v2(None, {"snap": snap, "serial": SERIAL}, message(payload))
        self.assertFalse(snap.online())
        self.assertEqual(snap.copy_print(), {})

    def test_message_ingests_report(self):
        snap = snapshot()
        body = json.dumps({"print": {"gcode_state": "RUNNING", "mc_percent": 3}}).encode()
        bambu._on_message_v2(None, {"snap": snap, "serial": SERIAL}, message(body))
        self.assertTrue(snap.online())
        self.assertEqual(snap.copy_print(), {"gcode_state": "RUNNING", "mc_percent": 3})


class ConfigTests(unittest.TestCase):
    def test_missing_required_env_exits(self):
        for key in ENV:
            env = {k: v for k, v in ENV.items() if k != key}
            with self.subTest(missing=key), mock.patch.dict(os.environ, env, clear=True):
                with self.assertRaises(SystemExit):
                    bambu.config_from_env()

    def test_whitespace_only_counts_as_missing(self):
        for key in ENV:
            with self.subTest(blank=key), mock.patch.dict(os.environ, {**ENV, key: " \t "}, clear=True):
                with self.assertRaises(SystemExit):
                    bambu.config_from_env()

    def test_name_defaults_to_x2d(self):
        with mock.patch.dict(os.environ, ENV, clear=True):
            self.assertEqual(bambu.config_from_env(), (PRINTER_IP, SERIAL, ACCESS_CODE, "X2D"))
        with mock.patch.dict(os.environ, {**ENV, "BAMBU_NAME": "  "}, clear=True):
            self.assertEqual(bambu.config_from_env()[3], "X2D")
        with mock.patch.dict(os.environ, {**ENV, "BAMBU_IP": f" {PRINTER_IP} ", "BAMBU_NAME": " Shop "}, clear=True):
            self.assertEqual(bambu.config_from_env(), (PRINTER_IP, SERIAL, ACCESS_CODE, "Shop"))


@unittest.skipUnless(bambu.mqtt is not None, "paho-mqtt not installed")
class MakeClientTests(unittest.TestCase):
    def make(self):
        # connect_async only records the target; nothing connects without loop_start.
        client = bambu.make_client("192.0.2.1", SERIAL, ACCESS_CODE, snapshot())
        self.addCleanup(client.disconnect)
        return client

    def test_client_id_is_feed_scoped(self):
        """The Swift app uses pg-app-; sharing an id makes the printer drop one session."""
        cid = self.make()._client_id.decode()
        self.assertRegex(cid, rf"^pg-feed-{re.escape(SERIAL[-6:])}-[0-9a-f]{{1,4}}$")

    def test_username_is_bblp(self):
        self.assertEqual(self.make().username, "bblp")

    def test_callback_errors_dont_stop_the_network_thread(self):
        self.assertTrue(self.make().suppress_exceptions)


class LoopbackServer(ThreadingHTTPServer):
    def server_bind(self):
        """Skips HTTPServer's reverse DNS lookup (socket.getfqdn), which takes seconds on CI runners."""
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "127.0.0.1", self.server_address[1]


class HttpTests(unittest.TestCase):
    def setUp(self):
        for target, attr, value in (
            (print_loop.Handler, "log_message", lambda *a, **k: None),
            (print_loop, "STATS_TOKEN", ""),
        ):
            patcher = mock.patch.object(target, attr, value)
            patcher.start()
            self.addCleanup(patcher.stop)

        with print_loop._lock:
            saved = print_loop._snap_obj
        self.addCleanup(self.set_snap, saved)
        self.snap = snapshot({"gcode_state": "IDLE", "mc_percent": 100, "subtask_name": "Benchy"})
        self.set_snap(self.snap)

        server = LoopbackServer(("127.0.0.1", 0), print_loop.Handler)
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(thread.join, 5)
        self.addCleanup(server.shutdown)
        self.port = server.server_address[1]

    @staticmethod
    def set_snap(snap):
        with print_loop._lock:
            print_loop._snap_obj = snap

    def get(self, path: str, headers: dict | None = None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            conn.request("GET", path, headers=headers or {})
            resp = conn.getresponse()
            return resp, resp.read()
        finally:
            conn.close()

    def test_health(self):
        resp, body = self.get("/health")
        self.assertEqual(resp.status, 200)
        self.assertEqual(
            json.loads(body),
            {"ok": True, "updated_at": self.snap.last_report_iso(), "token_required": False},
        )

    def test_print_json_paths_serve_snapshot(self):
        for path in ("/print.json", "/print", "/print.json/", "/print.json?x=1"):
            with self.subTest(path=path):
                resp, body = self.get(path)
                self.assertEqual(resp.status, 200)
                self.assertEqual(body, self.snap.print_json_bytes())

    def test_root_lists_endpoints(self):
        resp, body = self.get("/")
        self.assertEqual(resp.status, 200)
        self.assertEqual(json.loads(body)["endpoints"], ["/print.json", "/health"])

    def test_unknown_path_404(self):
        for path in ("/nope", "/print.json.bak", "/healthz", "/print.jsonx"):
            with self.subTest(path=path):
                resp, body = self.get(path)
                self.assertEqual((resp.status, json.loads(body)), (404, {"error": "not found"}))

    def test_responses_are_no_store_with_exact_length(self):
        def check(path, headers=None):
            resp, body = self.get(path, headers)
            self.assertEqual(resp.getheader("Cache-Control"), "no-store")
            self.assertEqual(resp.getheader("Content-Type"), "application/json")
            self.assertEqual(int(resp.getheader("Content-Length")), len(body))
            json.loads(body)

        for path in ("/health", "/print.json", "/", "/nope"):
            with self.subTest(path=path):
                check(path)
        with mock.patch.object(print_loop, "STATS_TOKEN", "s3cret"), self.subTest(path="401"):
            check("/print.json")

    def test_print_json_without_snapshot_is_empty_doc(self):
        self.set_snap(None)
        resp, body = self.get("/print.json")
        self.assertEqual((resp.status, body), (200, print_loop._EMPTY_PRINT))
        self.assertEqual(json.loads(body)["printers"], [])
        _, health = self.get("/health")
        self.assertIsNone(json.loads(health)["updated_at"])

    def test_token_required_for_print_json(self):
        with mock.patch.object(print_loop, "STATS_TOKEN", "s3cret"):
            for path in ("/print.json", "/print"):
                for headers in ({}, {"X-Stats-Token": "wrong"}, {"X-Stats-Token": "S3CRET"}):
                    with self.subTest(path=path, headers=headers):
                        resp, body = self.get(path, headers)
                        self.assertEqual(resp.status, 401)
                        self.assertNotIn(b"s3cret", body)
                with self.subTest(path=path, headers="right"):
                    resp, body = self.get(path, {"X-Stats-Token": "s3cret"})
                    self.assertEqual((resp.status, body), (200, self.snap.print_json_bytes()))

    def test_health_open_when_token_set(self):
        with mock.patch.object(print_loop, "STATS_TOKEN", "s3cret"):
            resp, body = self.get("/health")
        self.assertEqual(resp.status, 200)
        self.assertTrue(json.loads(body)["token_required"])

    def test_server_header_hides_the_python_version(self):
        resp, _ = self.get("/health")
        self.assertEqual(resp.getheader("Server"), "PrintGlance-feed/1.0")

    def test_idle_connection_is_closed(self):
        """A keep-alive connection that sends nothing gives its thread back."""
        self.assertIsNotNone(print_loop.Handler.timeout, "None waits forever")
        self.assertLessEqual(print_loop.Handler.timeout, 30)
        with mock.patch.object(print_loop.Handler, "timeout", 0.2):
            sock = socket.create_connection(("127.0.0.1", self.port), timeout=5)
            self.addCleanup(sock.close)
            self.assertEqual(sock.recv(1), b"", "the server hung up")

    def test_responses_never_leak_printer_secrets(self):
        with mock.patch.dict(os.environ, {**ENV, "BAMBU_NAME": "Workshop"}, clear=True):
            ip, serial, code, name = bambu.config_from_env()
        snap = bambu.BambuSnapshot("x2d", name)  # as print_loop.main builds it
        report = {"print": {
            "gcode_state": "RUNNING",
            "mc_percent": 12,
            "subtask_name": "Benchy",
            "sn": serial,
            "net": {"info": [{"ip": ip}]},
            "upgrade_state": {"sn": serial, "access_code": code},
        }}
        bambu._on_message_v2(None, {"snap": snap, "serial": serial}, message(json.dumps(report).encode()))
        self.set_snap(snap)

        resp, body = self.get("/print.json")
        row = json.loads(body)["printers"][0]
        self.assertEqual((row["id"], row["name"], row["state"], row["job"]), ("x2d", "Workshop", "RUNNING", "Benchy"))
        for path in ("/print.json", "/health", "/"):
            _, body = self.get(path)
            for secret in (serial, serial[-6:], code, ip):
                with self.subTest(path=path, secret=secret):
                    self.assertNotIn(secret.encode(), body)


class BindTests(unittest.TestCase):
    def test_serves_only_this_mac_by_default(self):
        self.assertEqual(print_loop.bind_address({}), ("127.0.0.1", 8080))
        self.assertEqual(print_loop.bind_address({"PRINT_HOST": "0.0.0.0", "PRINT_PORT": "9000"}), ("0.0.0.0", 9000))

    def test_warns_when_the_lan_can_read_it_without_a_token(self):
        for host in ("0.0.0.0", "192.0.2.5", "::", "mac.local"):
            with self.subTest(host=host):
                self.assertIn("STATS_TOKEN", print_loop.lan_warning(host, ""))
                self.assertIsNone(print_loop.lan_warning(host, "s3cret"))
        for host in ("127.0.0.1", "::1", "localhost"):
            with self.subTest(host=host):
                self.assertIsNone(print_loop.lan_warning(host, ""))


class SelfTestTests(unittest.TestCase):
    def test_self_test_passes(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(bambu.self_test(), 0)
        self.assertIn("self-test ok", out.getvalue())


if __name__ == "__main__":
    unittest.main()
