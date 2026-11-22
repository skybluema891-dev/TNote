"""Regression tests use an independent Git repository and ephemeral Ed25519 key."""
import argparse
import contextlib
import hashlib
import io
import os
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest
from unittest.mock import MagicMock, patch
from zipfile import ZipFile
import xml.etree.ElementTree as ET

import candidate_release as release


class CandidateReleaseTests(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.temp = Path(self.stack.enter_context(tempfile.TemporaryDirectory())).resolve()
        self.repo = self.temp / "repo"
        self.repo.mkdir()
        self.stack.enter_context(contextlib.chdir(self.repo))
        release.git("init", "--quiet")
        release.git("config", "core.autocrlf", "false")
        release.git("config", "core.hooksPath", str(self.temp / "no-hooks"))
        release.git("config", "commit.gpgSign", "false")
        release.git("config", "tag.gpgSign", "false")
        release.git("remote", "add", "origin", f"https://github.com/{release.REPO}.git")
        private = release.openssl("genpkey", "-algorithm", "ED25519", "-outform", "DER")
        public = release.openssl("pkey", "-inform", "DER", "-pubout", "-outform", "DER", data=private)
        self.info = {"SUPublicEDKey": release.b64(public[len(release.SPKI_PREFIX):]),
                     "SUFeedURL": release.FEED_URL, "SURequireSignedFeed": True,
                     "SUVerifyUpdateBeforeExtraction": True, "CFBundleShortVersionString": "4.5.6",
                     "CFBundleVersion": "12", "LSMinimumSystemVersion": "12.0"}
        plist = Path("macos/Runner/Info.plist")
        plist.parent.mkdir(parents=True)
        plist.write_bytes(plistlib.dumps(self.info))
        Path("pubspec.yaml").write_text("version: 4.5.6+12\n", encoding="utf-8")
        release.git("add", "pubspec.yaml", str(plist))
        release.git("-c", "user.name=TNote Test", "-c", "user.email=test@example.invalid",
                    "commit", "-qm", "release fixture")
        release.git("config", "user.name", "TNote Test")
        release.git("config", "user.email", "test@example.invalid")
        self.commit = release.git("rev-parse", "HEAD").decode().strip()
        self.stack.enter_context(patch.dict(os.environ, GITHUB_REPOSITORY=release.REPO, GITHUB_SHA=self.commit,
                                            GITHUB_RUN_ID="123", GITHUB_RUN_ATTEMPT="1", GITHUB_TOKEN="fixture"))
        self.zip = self.temp / "candidate.zip"
        self.dmg = b"synthetic release artifact\n"
        with ZipFile(self.zip, "w") as z:
            z.writestr("TNote-4.5.6.dmg", self.dmg)
            z.writestr("candidate-provenance.json", release.canonical(release.provenance(self.info)))
        repo = {"full_name": release.REPO, "id": 7}
        self.run = {"id": 123, "event": "push", "status": "completed", "conclusion": "success",
                    "head_branch": "candidate/test", "head_sha": self.commit, "run_attempt": 1,
                    "workflow_id": 11, "path": release.WORKFLOW, "repository": repo, "head_repository": repo}
        self.artifact = {"name": "macos-release", "id": 42, "expired": False, "size_in_bytes": self.zip.stat().st_size,
                         "digest": "sha256:" + release.digest(self.zip),
                         "workflow_run": {"id": 123, "repository_id": 7, "head_repository_id": 7, "head_sha": self.commit}}
        self.stack.enter_context(patch.object(release, "api", side_effect=self.api))
        self.stack.enter_context(patch.object(release, "download",
            side_effect=lambda record, path, token: shutil.copyfile(self.zip, path)))
        self.private_path = self.temp / "dedicated-fixture.dpapi"
        if os.name == "nt":
            import win32crypt
            self.private_path.write_bytes(win32crypt.CryptProtectData(private, "TNote unit test", None, None, None, 1))
        else:
            self.stack.enter_context(patch.object(release, "checked_signer",
                side_effect=lambda _: release.Ed25519Signer(private)))

    def api(self, path, token):
        if path == "actions/runs/123":
            return self.run
        if path == "actions/workflows/release.yml":
            return {"id": 11, "path": release.WORKFLOW}
        if path == "actions/runs/123/artifacts?per_page=100":
            return {"total_count": 1, "artifacts": [self.artifact]}
        self.fail("Unexpected API route")

    def stage(self, name):
        path = self.temp / name
        path.mkdir()
        return path

    def sign(self):
        args = argparse.Namespace(run=123, archive=self.zip, key=self.private_path, output=None, create_tag=True)
        release.prepare(args, self.stage("signing"))

    def promote(self):
        args = argparse.Namespace(tag="v4.5.6", assets=self.temp / "promoted")
        release.promote(args, self.stage("verify"))
        return args.assets

    def test_verified_candidate_tag_promotes_exact_archive_and_signed_feed(self):
        self.sign()
        payload = release.tag_payload("v4.5.6")
        assets = self.promote()
        self.assertEqual((assets / "TNote-4.5.6.dmg").read_bytes(), self.dmg)
        release.verify_release_feed(assets, self.stage("consumer"))
        feed = (assets / "appcast.xml").read_bytes()
        content, tail = feed.split(b"<!-- sparkle-signatures:\n")
        self.assertEqual(tail, f"edSignature: {payload['feed']}\nlength: {len(content)}\n-->\n".encode())
        item = ET.fromstring(content).find("channel/item")
        self.assertEqual(item.findtext(f"{{{release.NS}}}version"), "12")
        self.assertEqual(item.find("enclosure").attrib[f"{{{release.NS}}}edSignature"], payload["dmg"])
        self.assertEqual(payload["record"]["dmg_sha256"], hashlib.sha256(self.dmg).hexdigest())

    def test_failed_fork_or_wrong_workflow_cannot_be_signed(self):
        for key, value in [("event", "pull_request"), ("conclusion", "failure"), ("head_sha", "0" * 40),
                           ("head_repository", {"id": 9, "full_name": "example/other"}),
                           ("path", ".github/workflows/other.yml"), ("head_branch", "untrusted")]:
            with self.subTest(key=key), patch.dict(self.run, {key: value}), self.assertRaises(ValueError):
                release.candidate(123, self.commit)

    def test_final_dmg_must_verify_with_the_key_embedded_in_the_app(self):
        self.sign()
        assets = self.promote()
        (assets / "TNote-4.5.6.dmg").write_bytes(b"x" * len(self.dmg))
        with self.assertRaises(ValueError):
            release.verify_release_feed(assets, self.stage("recipient"))

    def test_existing_gh_downloads_the_exact_zip_without_interaction(self):
        record = release.candidate(123, self.commit)
        process = MagicMock()
        process.__enter__.return_value = process
        process.stdout = io.BytesIO(self.zip.read_bytes())
        process.wait.return_value = 0
        archive = self.temp / "cli-download.zip"
        with patch.object(release.shutil, "which", return_value="gh"), patch.object(
                release.subprocess, "Popen", return_value=process) as start:
            release.download_with_gh(record, archive)
        self.assertEqual(start.call_args.args[0], ["gh", "api", "--hostname", "github.com",
                         f"/repos/{release.REPO}/actions/artifacts/42/zip"])
        self.assertEqual(start.call_args.kwargs["env"]["GH_PROMPT_DISABLED"], "1")
        self.assertEqual(release.digest(archive), release.digest(self.zip))

    def test_changed_zip_rejected_before_unlocking_key(self):
        data = bytearray(self.zip.read_bytes())
        data[6] ^= 1
        self.zip.write_bytes(data)
        with patch.object(release, "checked_signer") as unlock, self.assertRaises(ValueError):
            self.sign()
        unlock.assert_not_called()

    def test_rerun_or_replaced_artifact_cannot_replace_attested_dmg(self):
        self.sign()
        self.run["run_attempt"] += 1
        with self.assertRaises(ValueError):
            self.promote()
        self.assertFalse((self.temp / "promoted").exists())

    def test_wrong_build_and_public_key_rejected_before_recording_provenance(self):
        for key in ("CFBundleVersion", "SUPublicEDKey"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                release.provenance(dict(self.info, **{key: "invalid"}))

    def test_changed_tag_content_invalidates_attestation(self):
        self.sign()
        payload = release.tag_payload("v4.5.6")
        payload["record"]["build"] += 1
        with patch.object(release, "tag_payload", return_value=payload), self.assertRaises(ValueError):
            self.promote()
        self.assertFalse((self.temp / "promoted").exists())


if __name__ == "__main__":
    unittest.main()
