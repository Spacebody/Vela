from __future__ import annotations

import platform
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Release/scripts/atomic_publish_directory.py"


@unittest.skipUnless(platform.system() == "Darwin", "renameatx_np is macOS-specific")
class AtomicDirectoryPublicationTests(unittest.TestCase):
    def run_script(self, source: Path, destination: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            (sys.executable, str(SCRIPT), str(source), str(destination)),
            text=True,
            capture_output=True,
        )

    def test_exact_source_inode_is_published(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source = root / "pending"
            destination = root / "final"
            source.mkdir()
            (source / "payload").write_text("candidate\n", encoding="utf-8")
            inode = source.stat().st_ino
            result = self.run_script(source, destination)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(source.exists())
            self.assertEqual(destination.stat().st_ino, inode)
            self.assertEqual((destination / "payload").read_text(), "candidate\n")

    def test_existing_destination_is_never_used_as_a_container(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source = root / "pending"
            destination = root / "final"
            source.mkdir()
            destination.mkdir()
            (source / "payload").write_text("candidate\n", encoding="utf-8")
            (destination / "sentinel").write_text("existing\n", encoding="utf-8")
            result = self.run_script(source, destination)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(source.is_dir())
            self.assertFalse((destination / "pending").exists())
            self.assertEqual((destination / "sentinel").read_text(), "existing\n")

    def test_source_parent_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            real_source_parent = root / "real-source"
            destination_parent = root / "destination"
            real_source_parent.mkdir()
            destination_parent.mkdir()
            source = real_source_parent / "pending"
            source.mkdir()
            (source / "payload").write_text("candidate\n", encoding="utf-8")
            source_parent_alias = root / "source-alias"
            source_parent_alias.symlink_to(real_source_parent, target_is_directory=True)

            result = self.run_script(
                source_parent_alias / "pending",
                destination_parent / "final",
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(source.is_dir())
            self.assertFalse((destination_parent / "final").exists())

    def test_distinct_parent_directories_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source_parent = root / "source"
            destination_parent = root / "destination"
            source_parent.mkdir()
            destination_parent.mkdir()
            source = source_parent / "pending"
            destination = destination_parent / "final"
            source.mkdir()
            (source / "payload").write_text("candidate\n", encoding="utf-8")

            result = self.run_script(source, destination)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must share the exact parent directory", result.stderr)
            self.assertTrue(source.is_dir())
            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
