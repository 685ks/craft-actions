import os
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "app_meta.py"
FIXTURE = Path(__file__).resolve().parents[1] / "test-fixtures" / "hello-craft"

BASE_ENV = {
    "APP_ID": "hello-craft",
    "DISPLAY_NAME": "HelloCraft",
    "BUNDLE_ID": "app.freedev.ainz.ks.HelloCraft",
    "VERSION": "0.1.0",
    "PACKAGE": "hello-craft",
    "BIN": "hello-craft",
    "FEATURES": "",
    "PUBLISH": "false",
    "PRERELEASE": "false",
    "REPOSITORY": "685ks/craft-actions",
    "OWNER": "685ks",
}


def run(app_dir, **overrides):
    env = {k: v for k, v in os.environ.items() if k != "GITHUB_OUTPUT"}
    env.update(BASE_ENV, APP_DIR=str(app_dir), **overrides)
    p = subprocess.run([sys.executable, "-I", str(SCRIPT)], env=env, capture_output=True, text=True)
    outputs = dict(line.split("=", 1) for line in p.stdout.splitlines() if "=" in line and not line.startswith("::"))
    return p.returncode, outputs, p.stdout


def png(size):
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    raw = b"".join(b"\0" + b"\0\0\0\0" * size[0] for _ in range(size[1]))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size[0], size[1], 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


@unittest.skipIf(sys.version_info < (3, 11), "app_meta.py needs tomllib")
class AppMeta(unittest.TestCase):
    def test_the_fixture_is_valid(self):
        code, out, log = run(FIXTURE)
        self.assertEqual(code, 0, log)
        self.assertEqual(out["version"], "0.1.0")
        self.assertEqual(out["tag"], "v0.1.0")
        self.assertEqual(out["prerelease"], "false")
        self.assertEqual(out["categories"], "Utility;Development;")
        self.assertEqual(out["icon-png"], "packaging/icon.png")
        self.assertEqual(out["publisher"], "685ks")
        self.assertRegex(out["upgrade-code"], r"^[0-9A-F-]{36}$")

    def test_a_leading_v_is_dropped_and_prereleases_are_flagged(self):
        code, out, log = run(FIXTURE, VERSION="v1.2.3-rc.1")
        self.assertEqual(code, 0, log)
        self.assertEqual((out["version"], out["tag"], out["prerelease"], out["msi-version"]), ("1.2.3-rc.1", "v1.2.3-rc.1", "true", "1.2.3"))

    def test_the_upgrade_code_is_stable(self):
        a = run(FIXTURE)[1]["upgrade-code"]
        b = run(FIXTURE, VERSION="9.9.9")[1]["upgrade-code"]
        self.assertEqual(a, b)

    def test_bad_inputs_are_refused(self):
        for key, value in [
            ("VERSION", "1.2"), ("VERSION", "1.2.3+build"), ("VERSION", "01.2.3"), ("VERSION", "1.2.3; rm -rf /"),
            ("APP_ID", "PhotoCraft"), ("APP_ID", "photo_craft"), ("APP_ID", "a--b"),
            ("BUNDLE_ID", "photocraft"), ("DISPLAY_NAME", "a/b"), ("DISPLAY_NAME", ""),
            ("BIN", "a b"), ("PACKAGE", "$(x)"), ("FEATURES", "a;b"), ("VERSION", "256.0.0"),
        ]:
            code, _, log = run(FIXTURE, **{key: value})
            self.assertNotEqual(code, 0, f"{key}={value!r} was accepted:\n{log}")

    def test_app_toml_is_checked(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "packaging").mkdir()
            self.assertNotEqual(run(d)[0], 0)  # no app.toml
            (d / "packaging" / "icon.png").write_bytes(png((300, 200)))
            (d / "packaging" / "app.toml").write_text(
                'description = "x"\ncategories = ["Graphics"]\nicon_png = "packaging/icon.png"\nlicense = "MIT"\n')
            code, _, log = run(d)
            self.assertNotEqual(code, 0)
            self.assertIn("square", log)
            (d / "packaging" / "icon.png").write_bytes(png((256, 256)))
            self.assertEqual(run(d)[0], 0)
            (d / "packaging" / "app.toml").write_text(
                'description = "x"\ncategories = ["Graphics"]\nicon_png = "../icon.png"\nlicense = "MIT"\n')
            self.assertNotEqual(run(d)[0], 0)


if __name__ == "__main__":
    unittest.main()
