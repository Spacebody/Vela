from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ReleaseCandidate/scripts/validate_pr_change_control.py"


def valid_body(**overrides: str) -> str:
    values = {
        "changeClass": "crashFix",
        "issueID": "VELA-RC-201",
        "severity": "high",
        "userImpact": "Prevents a startup crash for affected users",
        "securityImpact": "none",
        "contractImpact": "none",
        "migrationImpact": "none",
        "testEvidence": "VelaTests/ReleaseCandidateResourceReaderTests",
        "releaseNoteImpact": "Documented in the RC release notes",
        "reviewer": "@Spacebody",
    }
    values.update(overrides)
    lines = [
        "# Pull request",
        "",
        "<!-- VELA-FEATURE-FREEZE-CHANGE-CONTROL-START -->",
        "```yaml",
        *(f"{key}: {value}" for key, value in values.items()),
        "```",
        "<!-- VELA-FEATURE-FREEZE-CHANGE-CONTROL-END -->",
        "",
    ]
    return "\n".join(lines)


def run_validator(*arguments: str, environment: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    if environment:
        env.update(environment)
    return subprocess.run(
        (sys.executable, str(SCRIPT), *arguments),
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
    )


class PRChangeControlTests(unittest.TestCase):
    def run_body(self, body: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "body.md"
            path.write_text(body, encoding="utf-8")
            return run_validator("--body-file", str(path))

    def test_accepts_complete_body_file(self) -> None:
        result = self.run_body(valid_body())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("crashFix / high / VELA-RC-201", result.stdout)

    def test_accepts_github_event_path(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            event = Path(raw) / "event.json"
            event.write_text(
                json.dumps({"pull_request": {"body": valid_body(severity="informational")}}),
                encoding="utf-8",
            )
            result = run_validator(environment={"GITHUB_EVENT_PATH": str(event)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("informational", result.stdout)

    def test_rejects_missing_duplicate_empty_and_placeholder_fields(self) -> None:
        cases = {
            "missing": valid_body().replace("issueID: VELA-RC-201\n", ""),
            "duplicate": valid_body().replace(
                "issueID: VELA-RC-201\n", "issueID: VELA-RC-201\nissueID: VELA-RC-202\n"
            ),
            "empty": valid_body(userImpact=""),
            "placeholder": valid_body(testEvidence="REPLACE_ME"),
        }
        for name, body in cases.items():
            with self.subTest(name=name):
                result = self.run_body(body)
                self.assertNotEqual(result.returncode, 0)

    def test_rejects_invalid_change_class_and_severity(self) -> None:
        for name, body in {
            "changeClass": valid_body(changeClass="newFeature"),
            "severity": valid_body(severity="urgent"),
        }.items():
            with self.subTest(name=name):
                result = self.run_body(body)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{name} is not allowed", result.stderr)

    def test_rejects_duplicate_field_outside_control_block(self) -> None:
        result = self.run_body(valid_body() + "\nissueID: VELA-RC-OTHER\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("issueID must appear exactly once", result.stderr)

    def test_rejects_missing_or_repeated_markers(self) -> None:
        missing = valid_body().replace(
            "<!-- VELA-FEATURE-FREEZE-CHANGE-CONTROL-END -->", ""
        )
        repeated = valid_body() + "<!-- VELA-FEATURE-FREEZE-CHANGE-CONTROL-START -->\n"
        for body in (missing, repeated):
            with self.subTest(body=body[-80:]):
                result = self.run_body(body)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("exactly one change-control marker pair", result.stderr)

    def test_rejects_null_or_malformed_github_event(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            null_body = Path(raw) / "null.json"
            null_body.write_text(json.dumps({"pull_request": {"body": None}}), encoding="utf-8")
            malformed = Path(raw) / "malformed.json"
            malformed.write_text("{", encoding="utf-8")
            for event in (null_body, malformed):
                with self.subTest(event=event.name):
                    result = run_validator("--event-file", str(event))
                    self.assertNotEqual(result.returncode, 0)

    def test_rejects_symlink_body_file(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            target = directory / "body.md"
            target.write_text(valid_body(), encoding="utf-8")
            link = directory / "body-link.md"
            link.symlink_to(target)
            result = run_validator("--body-file", str(link))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("regular, non-symlink", result.stderr)

    def test_rejects_oversized_body_file(self) -> None:
        result = self.run_body(valid_body() + ("x" * (256 * 1024)))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exceeds the 262144-byte limit", result.stderr)


if __name__ == "__main__":
    unittest.main()
