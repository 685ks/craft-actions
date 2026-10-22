import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"


class UpdateFeed(unittest.TestCase):
    def test_lists_packages_by_platform_with_checksums(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            files = {
                "hello-craft-1.0.0-windows-x64.msi": b"msi",
                "hello-craft-1.0.0-windows-x64-portable.zip": b"zip",
                "hello-craft-1.0.0-sbom.cdx.json": b"{}",
            }
            for name, data in files.items():
                (d / name).write_bytes(data)
            subprocess.run(
                [sys.executable, "-I", str(SCRIPTS / "update_feed.py"), str(d), "--app-id", "hello-craft",
                 "--display-name", "HelloCraft", "--version", "1.0.0", "--tag", "v1.0.0",
                 "--repository", "o/r", "--date", "2026-01-02T03:04:05Z", "--signed", "true"],
                check=True, capture_output=True,
            )
            feed = json.loads((d / "update-feed.json").read_text())
        self.assertEqual(feed["schema"], 1)
        self.assertEqual((feed["id"], feed["version"], feed["tag"], feed["prerelease"]), ("hello-craft", "1.0.0", "v1.0.0", False))
        self.assertEqual(sorted(feed["platforms"]), ["windows-x64"])
        win = {e["kind"]: e for e in feed["platforms"]["windows-x64"]}
        self.assertEqual(win["msi"]["sha256"], hashlib.sha256(b"msi").hexdigest())
        self.assertEqual(win["msi"]["size"], 3)
        self.assertEqual(win["portable-zip"]["url"], "https://github.com/o/r/releases/download/v1.0.0/hello-craft-1.0.0-windows-x64-portable.zip")
        self.assertEqual(feed["signature_url"], "https://github.com/o/r/releases/download/v1.0.0/SHA256SUMS.txt.minisig")


if __name__ == "__main__":
    unittest.main()
