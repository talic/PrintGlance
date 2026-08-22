"""
Read-only Bambu LAN MQTT snapshot for PrintGlance.

Merges partial `print` reports (P-series deltas). Never publishes pause/stop/print.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import ssl
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from typing import Any

log = logging.getLogger("bambu")

MQTT_PORT = 8883
MQTT_USER = "bblp"
STALE_AFTER_S = 120
ACTIVE_STATES = ("PREPARE", "RUNNING")
KNOWN_STATES = ("PREPARE", "RUNNING", "PAUSE", "FINISH", "FAILED", "IDLE", "OFFLINE")

# paho-mqtt is optional until print_loop / --once runs.
try:
    import paho.mqtt.client as mqtt
except ImportError:  # pragma: no cover
    mqtt = None  # type: ignore


def _env(name: str, default: str = "") -> str:
    v = os.environ.get(name)
    if v is None or not str(v).strip():
        return default
    return str(v).strip()


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


_JOB_ID_KEYS = ("task_id", "subtask_id", "subtask_name")
_JOB_CLEAR_KEYS = ("layer_num", "total_layer_num", "gcode_file")


def _job_id_changed(dst: dict[str, Any], incoming: dict[str, Any]) -> bool:
    for k in _JOB_ID_KEYS:
        if k not in incoming:
            continue
        old, new = dst.get(k), incoming.get(k)
        if old in (None, "") or new in (None, ""):
            continue
        if old != new:
            return True
    return False


def merge_print(dst: dict[str, Any], incoming: dict[str, Any]) -> None:
    """Copy present keys from a MQTT `print` object. Missing keys keep last.

    When the job identity changes, drop layer/gcode so a delta cannot keep
    the previous print's progress.
    """
    if not incoming:
        return
    if _job_id_changed(dst, incoming):
        for k in _JOB_CLEAR_KEYS:
            dst.pop(k, None)
    for k, v in incoming.items():
        dst[k] = v


def _int_or_none(v: Any) -> int | None:
    if v is None or v == "":
        return None
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def human_gcode_stem(gcode_file: Any) -> str | None:
    if not isinstance(gcode_file, str) or not gcode_file.strip():
        return None
    s = gcode_file.strip().replace("\\", "/")
    low = s.lower()
    if low.startswith("cache/") or "/cache/" in low:
        return None
    base = s.rsplit("/", 1)[-1]
    stem = base
    for ext in (".gcode", ".3mf", ".gco"):
        if stem.lower().endswith(ext):
            stem = stem[: -len(ext)]
            break
    if len(stem) < 2:
        return None
    if re.fullmatch(r"[0-9a-fA-F]{8,}", stem) or re.fullmatch(r"\d{6,}", stem):
        return None
    return stem


def strip_process_suffix(name: str) -> str:
    return re.sub(r"\s+\d+(\.\d+)?mm\b.*", "", name, flags=re.I).strip()


def job_label(print_obj: dict[str, Any]) -> str | None:
    stem = human_gcode_stem(print_obj.get("gcode_file"))
    if stem:
        label = stem
    else:
        raw = print_obj.get("subtask_name")
        if not isinstance(raw, str) or not raw.strip():
            return None
        stripped = strip_process_suffix(raw)
        label = stripped or raw.strip()
    if len(label) > 40:
        label = label[:37] + "..."
    return label or None


def _find_ams_tray(ams: dict[str, Any], idx: int) -> dict[str, Any] | None:
    units = ams.get("ams")
    if not isinstance(units, list):
        return None
    for unit in units:
        if not isinstance(unit, dict):
            continue
        trays = unit.get("tray")
        if not isinstance(trays, list):
            continue
        for tray in trays:
            if not isinstance(tray, dict):
                continue
            tid = _int_or_none(tray.get("id"))
            if tid == idx:
                return tray
    return None


def _remain_percent(raw: Any) -> int | None:
    """Remaining filament percent. Values below 0 mean no sensor and become None."""
    remain = _int_or_none(raw)
    if remain is None or remain < 0:
        return None
    return min(100, remain)


def active_filament(print_obj: dict[str, Any]) -> tuple[str | None, int | None]:
    """Active AMS (or external) tray type and remain %."""
    ams = print_obj.get("ams")
    if not isinstance(ams, dict):
        ams = {}
    now = _int_or_none(ams.get("tray_now"))
    if now is None:
        now = _int_or_none(ams.get("tray_tar"))
    tray: dict[str, Any] | None = None
    if now is None or now == 255:
        return None, None
    if now == 254:
        vt = print_obj.get("vt_tray")
        if isinstance(vt, dict):
            tray = vt
        else:
            return None, None
    else:
        tray = _find_ams_tray(ams, now)
        if tray is None:
            return None, None
    raw_type = tray.get("tray_type") or tray.get("type")
    fil = None
    if isinstance(raw_type, str):
        fil = raw_type.strip()[:8] or None
    return fil, _remain_percent(tray.get("remain"))


def eta_hm(state: str, remaining_s: int | None) -> str | None:
    if state not in ("RUNNING", "PREPARE", "PAUSE"):
        return None
    if remaining_s is None or remaining_s <= 0:
        return None
    t = datetime.now().astimezone() + timedelta(seconds=remaining_s)
    return t.strftime("%H:%M")


def printer_row(
    printer_id: str,
    name: str,
    print_obj: dict[str, Any],
    *,
    online: bool,
) -> dict[str, Any]:
    raw = str(print_obj.get("gcode_state") or "").upper()
    if not online:
        state = "OFFLINE"
    elif raw in KNOWN_STATES:
        state = raw
    elif raw:
        state = raw
    else:
        state = "OFFLINE"

    percent = print_obj.get("mc_percent")
    try:
        percent_i = int(percent) if percent is not None else None
    except (TypeError, ValueError):
        percent_i = None
    if percent_i is not None:
        percent_i = max(0, min(100, percent_i))

    remaining_min = print_obj.get("mc_remaining_time")
    remaining_s = None
    try:
        if remaining_min is not None:
            remaining_s = max(0, int(remaining_min) * 60)
    except (TypeError, ValueError):
        remaining_s = None

    job = job_label(print_obj)
    filament, filament_remain = active_filament(print_obj)

    layer = None
    layer_total = None
    if "layer_num" in print_obj:
        layer = _int_or_none(print_obj.get("layer_num"))
    if "total_layer_num" in print_obj:
        layer_total = _int_or_none(print_obj.get("total_layer_num"))

    return {
        "id": printer_id,
        "name": name,
        "state": state,
        "percent": percent_i,
        "remaining_s": remaining_s,
        "job": job,
        "layer": layer,
        "layer_total": layer_total,
        "eta": eta_hm(state, remaining_s),
        "filament": filament,
        "filament_remain": filament_remain,
    }


def pick_focus_id(printers: list[dict[str, Any]]) -> str | None:
    for want in ACTIVE_STATES:
        for p in printers:
            if str(p.get("state") or "").upper() == want:
                return p.get("id")
    for p in printers:
        if str(p.get("state") or "").upper() == "PAUSE":
            return p.get("id")
    for p in printers:
        if str(p.get("state") or "").upper() != "OFFLINE":
            return p.get("id")
    return printers[0]["id"] if printers else None


def build_doc(
    printer_id: str,
    name: str,
    print_obj: dict[str, Any],
    *,
    online: bool,
    updated_at: str | None = None,
) -> dict[str, Any]:
    row = printer_row(printer_id, name, print_obj, online=online)
    printers = [row]
    return {
        "v": 1,
        "updated_at": updated_at,
        "focus_id": pick_focus_id(printers),
        "printers": printers,
    }


class BambuSnapshot:
    """Thread-safe merged print snapshot for one LAN printer."""

    def __init__(self, printer_id: str, name: str) -> None:
        self.printer_id = printer_id
        self.name = name
        self._lock = threading.Lock()
        self._print: dict[str, Any] = {}
        self._last_report = 0.0
        self._last_report_iso: str | None = None
        self._gen = 0
        self._connected = False
        self._http_key: tuple[int, bool] | None = None
        self._http_body: bytes | None = None

    def mark_connected(self, ok: bool) -> None:
        with self._lock:
            self._connected = ok

    def ingest(self, payload: dict[str, Any]) -> None:
        print_obj = payload.get("print")
        if not isinstance(print_obj, dict) or not print_obj:
            return
        with self._lock:
            merge_print(self._print, print_obj)
            self._last_report = time.monotonic()
            self._last_report_iso = utc_now_iso()
            self._gen += 1
            self._connected = True

    def _online_locked(self) -> bool:
        if not self._connected:
            return False
        if self._last_report <= 0:
            return False
        return (time.monotonic() - self._last_report) < STALE_AFTER_S

    def online(self) -> bool:
        with self._lock:
            return self._online_locked()

    def last_report_iso(self) -> str | None:
        with self._lock:
            return self._last_report_iso

    def copy_print(self) -> dict[str, Any]:
        with self._lock:
            return dict(self._print)

    def document(self) -> dict[str, Any]:
        with self._lock:
            print_obj = dict(self._print)
            fresh = self._online_locked()
            iso = self._last_report_iso
        return build_doc(
            self.printer_id, self.name, print_obj, online=fresh, updated_at=iso
        )

    def print_json_bytes(self) -> bytes:
        """Serialized /print.json, rebuilt when ingest gen or online() changes."""
        with self._lock:
            fresh = self._online_locked()
            key = (self._gen, fresh)
            if self._http_body is not None and self._http_key == key:
                return self._http_body
            print_obj = dict(self._print)
            iso = self._last_report_iso
        body = json.dumps(
            build_doc(
                self.printer_id, self.name, print_obj, online=fresh, updated_at=iso
            ),
            separators=(",", ":"),
        ).encode("utf-8")
        with self._lock:
            if (self._gen, self._online_locked()) == key:
                self._http_key = key
                self._http_body = body
        return body


def _on_connect_v2(client, userdata, flags, reason_code, properties) -> None:  # noqa: ANN001
    snap: BambuSnapshot = userdata["snap"]
    serial = userdata["serial"]
    failed = bool(getattr(reason_code, "is_failure", False))
    if not hasattr(reason_code, "is_failure"):
        try:
            failed = int(reason_code) != 0
        except (TypeError, ValueError):
            failed = str(reason_code) not in ("Success", "0")
    if failed:
        log.warning("mqtt connect failed rc=%s", reason_code)
        snap.mark_connected(False)
        return
    log.info("mqtt connected")
    snap.mark_connected(True)
    client.subscribe(f"device/{serial}/report", qos=0)
    client.publish(
        f"device/{serial}/request",
        json.dumps({"pushing": {"command": "pushall", "sequence_id": "0"}}),
        qos=0,
    )


def _on_message_v2(client, userdata, message) -> None:  # noqa: ANN001, ARG001
    snap: BambuSnapshot = userdata["snap"]
    try:
        payload = json.loads(message.payload.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return
    if isinstance(payload, dict):
        snap.ingest(payload)


def make_client(ip: str, serial: str, access_code: str, snap: BambuSnapshot):
    if mqtt is None:
        raise SystemExit("paho-mqtt is not installed. pip install paho-mqtt")
    client = mqtt.Client(
        callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
        client_id=f"printglance-{serial[-6:]}",
        protocol=mqtt.MQTTv311,
    )
    client.user_data_set({"snap": snap, "serial": serial})
    client.username_pw_set(MQTT_USER, access_code)
    client.tls_set(cert_reqs=ssl.CERT_NONE)
    client.tls_insecure_set(True)
    client.on_connect = _on_connect_v2
    client.on_message = _on_message_v2
    client.reconnect_delay_set(min_delay=1, max_delay=30)
    client.connect_async(ip, MQTT_PORT, keepalive=30)
    return client


def config_from_env() -> tuple[str, str, str, str]:
    ip = _env("BAMBU_IP")
    serial = _env("BAMBU_SERIAL")
    code = _env("BAMBU_ACCESS_CODE")
    name = _env("BAMBU_NAME", "X2D")
    if not ip or not serial or not code:
        raise SystemExit(
            "BAMBU_IP, BAMBU_SERIAL, and BAMBU_ACCESS_CODE must be set in the environment"
        )
    return ip, serial, code, name


def wait_for_state(snap: BambuSnapshot, timeout_s: float = 12.0) -> dict[str, Any] | None:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        doc = snap.document()
        row = (doc.get("printers") or [{}])[0]
        if row.get("state") and row.get("state") != "OFFLINE":
            return doc
        time.sleep(0.2)
    return None


def self_test() -> int:
    dst: dict[str, Any] = {"gcode_state": "RUNNING", "mc_percent": 40, "subtask_name": "job.3mf"}
    merge_print(dst, {"sequence_id": "1"})
    assert dst["gcode_state"] == "RUNNING", dst
    assert dst["mc_percent"] == 40, dst
    merge_print(dst, {"mc_percent": 41})
    assert dst["mc_percent"] == 41, dst
    row = printer_row("x2d", "X2D", {"gcode_state": "PREPARE", "mc_remaining_time": 2}, online=True)
    assert row["state"] == "PREPARE"
    assert row["remaining_s"] == 120
    doc = build_doc("x2d", "X2D", {"gcode_state": "PREPARE"}, online=True)
    assert doc["focus_id"] == "x2d"
    offline = build_doc("x2d", "X2D", {"gcode_state": "RUNNING", "mc_percent": 62}, online=False)
    assert offline["printers"][0]["state"] == "OFFLINE"
    assert offline["printers"][0]["percent"] == 62

    assert human_gcode_stem("cache/012345678.gcode") is None
    assert human_gcode_stem("models/stomp-t-rex.gcode") == "stomp-t-rex"
    raw_name = "Print in Parts 0.16mm layer, 2 walls, 10% infill"
    assert strip_process_suffix(raw_name) == "Print in Parts"
    assert job_label({"subtask_name": raw_name}) == "Print in Parts"
    assert job_label({"gcode_file": "cache/abc.gcode", "subtask_name": raw_name}) == "Print in Parts"

    dst2: dict[str, Any] = {
        "subtask_name": "old",
        "layer_num": 90,
        "gcode_file": "old.gcode",
        "gcode_state": "RUNNING",
    }
    merge_print(dst2, {"subtask_name": "new", "gcode_state": "RUNNING"})
    assert "layer_num" not in dst2, dst2
    assert "gcode_file" not in dst2, dst2
    row_new = printer_row("x2d", "X2D", dst2, online=True)
    assert row_new["layer"] is None
    merge_print(dst2, {"layer_num": 1, "total_layer_num": 10})
    row_l = printer_row("x2d", "X2D", dst2, online=True)
    assert row_l["layer"] == 1
    assert row_l["layer_total"] == 10

    z = printer_row(
        "x2d",
        "X2D",
        {"gcode_state": "PREPARE", "mc_remaining_time": 0},
        online=True,
    )
    assert z["remaining_s"] == 0
    assert z["eta"] is None
    run = printer_row(
        "x2d",
        "X2D",
        {"gcode_state": "RUNNING", "mc_remaining_time": 5},
        online=True,
    )
    assert run["eta"] and len(run["eta"]) == 5 and run["eta"][2] == ":"

    ams = {
        "tray_now": 1,
        "ams": [
            {
                "id": "0",
                "tray": [
                    {"id": "0", "tray_type": "ABS", "remain": 10},
                    {"id": "1", "tray_type": "PLA", "remain": 42},
                ],
            }
        ],
    }
    assert active_filament({"ams": ams}) == ("PLA", 42)
    assert active_filament({}) == (None, None)
    assert active_filament({"ams": {"tray_now": 255}}) == (None, None)
    assert active_filament(
        {"ams": {"tray_now": 254}, "vt_tray": {"tray_type": "PETG", "remain": 80}}
    ) == ("PETG", 80)
    assert active_filament(
        {
            "ams": {
                "tray_now": 1,
                "ams": [{"tray": [{"id": "1", "tray_type": "PLA", "remain": -1}]}],
            }
        }
    ) == ("PLA", None)
    assert active_filament(
        {"ams": {"tray_now": 254}, "vt_tray": {"tray_type": "PETG"}}
    ) == ("PETG", None)
    fil_row = printer_row("x2d", "X2D", {"gcode_state": "IDLE", "ams": ams}, online=True)
    assert fil_row["filament"] == "PLA"
    assert fil_row["filament_remain"] == 42

    snap = BambuSnapshot("x2d", "X2D")
    empty = snap.document()
    assert empty["updated_at"] is None
    assert empty["printers"][0]["state"] == "OFFLINE"
    snap.ingest({"print": {"gcode_state": "RUNNING", "mc_percent": 16}})
    b1 = snap.print_json_bytes()
    b2 = snap.print_json_bytes()
    assert b1 == b2
    run_doc = json.loads(b1)
    assert run_doc["printers"][0]["state"] == "RUNNING"
    assert run_doc["printers"][0]["percent"] == 16
    iso = run_doc["updated_at"]
    assert isinstance(iso, str) and iso.endswith("Z") and "T" in iso
    snap._last_report = time.monotonic() - (STALE_AFTER_S + 1)
    off_body = snap.print_json_bytes()
    off_doc = json.loads(off_body)
    assert off_doc["printers"][0]["state"] == "OFFLINE"
    assert off_doc["printers"][0]["percent"] == 16
    assert off_doc["updated_at"] == iso
    assert off_body != b1
    snap.ingest({"print": {"mc_percent": 17}})
    again = json.loads(snap.print_json_bytes())
    assert again["printers"][0]["state"] == "RUNNING"
    assert again["printers"][0]["percent"] == 17

    print("bambu self-test ok")
    return 0


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    p = argparse.ArgumentParser(description="Bambu LAN snapshot (read-only)")
    p.add_argument("--once", action="store_true", help="Connect, wait for one gcode_state, print JSON, exit")
    p.add_argument("--self-test", action="store_true")
    args = p.parse_args(argv)
    if args.self_test:
        return self_test()

    ip, serial, code, name = config_from_env()
    snap = BambuSnapshot("x2d", name)
    client = make_client(ip, serial, code, snap)
    client.loop_start()
    try:
        doc = wait_for_state(snap, timeout_s=15.0)
        if doc is None:
            log.error("no gcode_state within 15s (LAN / Developer Mode / access code?)")
            print(json.dumps(snap.document(), indent=2))
            return 2
        print(json.dumps(doc, indent=2))
        if not args.once:
            return 0
        return 0
    finally:
        client.loop_stop()
        client.disconnect()


if __name__ == "__main__":
    sys.exit(main())
