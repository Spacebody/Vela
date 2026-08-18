from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = ROOT / "ReleaseCandidate/templates/v1-go-no-go-minutes.md"


class GoNoGoMinutesTemplateTests(unittest.TestCase):
    def test_template_lists_all_ten_required_gates(self) -> None:
        text = TEMPLATE.read_text(encoding="utf-8")
        expected = (
            "For each required gate record status, immutable evidence, and accountable owner:\n"
            "Stop-Ship, contracts, migration, security audit, 72-hour soak, performance,\n"
            "accessibility/privacy, installation/update/rollback matrix, artifact/provenance,\n"
            "and support/incident."
        )
        self.assertIn(expected, text)


if __name__ == "__main__":
    unittest.main()
