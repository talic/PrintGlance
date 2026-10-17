"""The feed's copy of the report parser must match BambuPrint.

The fixture is the contract. A failure names the Swift function to copy.
"""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import bambu  # noqa: E402

FIXTURE = (
    Path(__file__).resolve().parents[1] / "PrintGlanceTests" / "Fixtures" / "parser-parity.json"
)
SOURCE = "BambuPrint in Sources/PrintGlance/BambuSnapshot.swift"


class ParserParityTests(unittest.TestCase):
    def test_feed_matches_bambu_print(self):
        cases = json.loads(FIXTURE.read_text())["cases"]
        for case in cases:
            with self.subTest(case=case["id"]):
                print_obj = case["print"]
                if "job" in case:
                    self.assertEqual(
                        bambu.job_label(print_obj),
                        case["job"],
                        f"{case['id']}: bambu.job_label drifted from BambuPrint.jobLabel "
                        f"({SOURCE}). Update bambu.py to match that function.",
                    )
                if "filament" in case:
                    filament, _remain = bambu.active_filament(print_obj)
                    self.assertEqual(
                        filament,
                        case["filament"],
                        f"{case['id']}: bambu.active_filament drifted from BambuPrint.activeFilament "
                        f"({SOURCE}). Update bambu._find_ams_tray to match it.",
                    )
                if "remainingS" in case:
                    row = bambu.printer_row("x", "X", print_obj, online=True)
                    self.assertEqual(
                        row["remaining_s"],
                        case["remainingS"],
                        f"{case['id']}: bambu.printer_row drifted from BambuPrint.row "
                        f"({SOURCE}). Cap remaining minutes with bambu.MAX_REMAINING_MIN.",
                    )
