"""The asset name grammar, checked against the cases the Craft launcher's own tests pin down
(crates/core/src/platform.rs in 685ks/craft-launcher)."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import asset_names as an  # noqa: E402

TOKENS = ["windows-x64"]


class Parse(unittest.TestCase):
    def test_reads_versions_tokens_and_kinds(self):
        n = an.parse("photocraft-0.2.0-rc.1-windows-arm64-portable.zip", ["photocraft"])
        self.assertEqual((n.version, n.token, n.kind), ("0.2.0-rc.1", "windows-arm64", "portable-zip"))
        n = an.parse("printcraft-0.2.1-linux-x86_64.tar.gz", ["pdfcraft", "printcraft"])
        self.assertEqual((n.stem, n.kind), ("printcraft", "tar.gz"))
        n = an.parse("photocraft-0.5.0-linux-aarch64.AppImage", ["photocraft"])
        self.assertEqual((n.token, n.kind), ("linux-aarch64", "appimage"))

    def test_other_files_are_not_packages(self):
        for other in [
            "photocraft-cli-0.5.0-macos-universal.zip",
            "photocraft-web-0.5.0.zip",
            "SHA256SUMS.txt",
            "SHA256SUMS.txt.minisig",
            "update-feed.json",
            "photocraft-0.5.0-sbom.cdx.json",
            "photocraft-0.5.0-linux-x86_64.AppImage.zsync",
        ]:
            self.assertIsNone(an.parse(other, ["photocraft"]), other)

    def test_a_longer_stem_is_not_the_app(self):
        self.assertIsNone(an.parse("figcraft-server-0.5.1-linux-x86_64.tar.gz", ["figcraft"]))
        self.assertIsNotNone(an.parse("figcraft-0.5.1-linux-x86_64.tar.gz", ["figcraft"]))

    def test_dashed_app_ids(self):
        n = an.parse("hello-craft-0.1.0-ci.7-linux-x86_64.deb", ["hello-craft"])
        self.assertEqual((n.version, n.token, n.kind), ("0.1.0-ci.7", "linux-x86_64", "deb"))

    def test_versions_must_be_semver_starting_with_a_digit(self):
        self.assertIsNone(an.parse("photocraft-v0.5.0-linux-x86_64.deb", ["photocraft"]))
        self.assertIsNone(an.parse("photocraft-latest-linux-x86_64.deb", ["photocraft"]))
        self.assertIsNone(an.parse("photocraft-linux-x86_64.AppImage", ["photocraft"]))
        self.assertIsNone(an.parse("photocraft-0.5.0-01-linux-x86_64.deb", ["photocraft"]))


class Names(unittest.TestCase):
    def test_every_name_the_workflow_makes_round_trips(self):
        for app in ["photocraft", "hello-craft", "deckcraft"]:
            for version in ["0.1.0", "1.20.3-rc.1", "0.1.0-ci.42", "2.0.0-beta.2.x-y"]:
                for token, kinds in an.EXPECTED.items():
                    for kind in kinds:
                        name = an.asset_name(app, version, token, kind)
                        self.assertEqual(an.parse(name, [app]), an.AssetName(app, version, token, kind), name)

    def full_release(self, app="hello-craft", version="0.1.0"):
        names = [an.asset_name(app, version, t, k) for t, ks in an.EXPECTED.items() for k in ks]
        names += ["SHA256SUMS.txt", "SHA256SUMS.txt.minisig", "update-feed.json", f"{app}-{version}-sbom.cdx.json"]
        return names

    def test_a_full_release_checks_out(self):
        self.assertEqual(an.check(self.full_release(), "hello-craft", "0.1.0", True), [])

    def test_problems_are_reported(self):
        names = self.full_release()
        names.remove("hello-craft-0.1.0-windows-x64.msi")
        names.append("hello-craft-0.1.1-windows-x64-portable.zip")
        names.append("notes.txt")
        names.append("hello-craft-0.1.0-linux-x86_64.tar.gz")
        names.append("hello-craft-0.1.0-linux-x86_64.AppImage.zsync")
        problems = "\n".join(an.check(names, "hello-craft", "0.1.0", True))
        self.assertIn("missing hello-craft-0.1.0-windows-x64.msi", problems)
        self.assertIn("version '0.1.1'", problems)
        self.assertIn("notes.txt", problems)
        self.assertIn("platform 'linux-x86_64'", problems)
        self.assertIn("hello-craft-0.1.0-linux-x86_64.AppImage.zsync: not a package name", problems)

    def test_the_built_tokens_are_the_contract(self):
        self.assertEqual(sorted(an.EXPECTED), sorted(TOKENS))


if __name__ == "__main__":
    unittest.main()
