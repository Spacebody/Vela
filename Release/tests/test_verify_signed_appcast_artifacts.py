from __future__ import annotations

import base64
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VERIFIER = ROOT / "Release/scripts/verify_signed_appcast_artifacts.py"
SIGNATURE = base64.b64encode(bytes(range(64))).decode("ascii")


class SignedAppcastArtifactTests(unittest.TestCase):
    def fixture(self, directory: Path) -> tuple[Path, Path, Path, Path]:
        notes = directory / "Vela-1.0.0-rc.1-arm64.md"
        dmg = directory / "Vela-1.0.0-rc.1-arm64.dmg"
        notes.write_bytes(b"signed notes bytes")
        dmg.write_bytes(b"signed dmg bytes")
        key = directory / "private.key"
        key.write_text("fixture", encoding="utf-8")
        fake = directory / "sign_update"
        fake.write_text(
            "#!/usr/bin/env python3\n"
            "import pathlib, sys\n"
            "expected = {b'signed notes bytes', b'signed dmg bytes'}\n"
            "ok = (len(sys.argv) == 6 and sys.argv[1:4] == "
            "['--verify', '--ed-key-file', sys.argv[3]] and "
            "pathlib.Path(sys.argv[4]).read_bytes() in expected)\n"
            "raise SystemExit(0 if ok else 1)\n",
            encoding="utf-8",
        )
        fake.chmod(0o700)
        appcast = directory / "appcast.xml"
        appcast.write_text(
            f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item>
    <sparkle:version>2026071403</sparkle:version>
    <sparkle:releaseNotesLink sparkle:edSignature="{SIGNATURE}" sparkle:length="{notes.stat().st_size}">https://updates.example.com/{notes.name}</sparkle:releaseNotesLink>
    <enclosure url="https://updates.example.com/{dmg.name}" sparkle:edSignature="{SIGNATURE}" length="{dmg.stat().st_size}" />
  </item></channel>
</rss>
''',
            encoding="utf-8",
        )
        return appcast, key, fake, dmg

    def run_verifier(self, appcast: Path, key: Path, fake: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(VERIFIER),
                str(appcast),
                "--artifacts-dir",
                str(appcast.parent),
                "--sign-update",
                str(fake),
                "--ed-key-file",
                str(key),
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_verifies_every_feed_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            appcast, key, fake, _ = self.fixture(Path(raw))
            result = self.run_verifier(appcast, key, fake)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Verified 2 Sparkle artifact signature(s)", result.stdout)

    def test_rejects_same_length_tampering_when_sparkle_rejects_signature(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            appcast, key, fake, dmg = self.fixture(Path(raw))
            dmg.write_bytes(b"tampered dmg byt")
            self.assertEqual(dmg.stat().st_size, len(b"signed dmg bytes"))
            result = self.run_verifier(appcast, key, fake)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("failed Sparkle Ed25519 verification", result.stderr)

    def test_rejects_symlink_anywhere_in_artifact_tree(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            appcast, key, fake, dmg = self.fixture(root)
            (root / "unsafe-link").symlink_to(dmg)
            result = self.run_verifier(appcast, key, fake)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("contains a symlink", result.stderr)


if __name__ == "__main__":
    unittest.main()
