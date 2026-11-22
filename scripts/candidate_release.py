"""Bind a tested macOS artifact to a release tag without sending the signing key to CI."""
import argparse
import base64
import ctypes
import ctypes.util
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
from urllib.parse import urlsplit
from urllib.request import build_opener, HTTPRedirectHandler, Request
from zipfile import ZipFile
import xml.etree.ElementTree as ET

REPO = "skybluema891-dev/TNote"
WORKFLOW = ".github/workflows/release.yml"
FORMAT = "TNote signed candidate v1"
NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
FEED_URL = f"https://github.com/{REPO}/releases/latest/download/appcast.xml"
SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")
PKCS8_PREFIX = bytes.fromhex("302e020100300506032b657004220420")
MAX_ARCHIVE = 1024 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii")


def git(*args, data=None):
    return subprocess.run(["git", *args], input=data, check=True, stdout=subprocess.PIPE).stdout


def version_info():
    content = Path("pubspec.yaml").read_text(encoding="utf-8")
    values = re.findall(r"^version: (\d+\.\d+\.\d+)\+([1-9]\d*)$", content, re.M | re.ASCII)
    require(len(values) == 1, "Invalid pubspec version/build")
    version, build = values[0]
    return version, int(build)


def public_key():
    info = plistlib.loads(Path("macos/Runner/Info.plist").read_bytes())
    key = base64.b64decode(info["SUPublicEDKey"], validate=True)
    require(len(key) == 32 and info.get("SUFeedURL") == FEED_URL, "Invalid app update identity")
    return key


def b64(value):
    return base64.b64encode(value).decode("ascii")


def signature_bytes(value):
    require(isinstance(value, str) and len(value) == 88, "Invalid signature")
    raw = base64.b64decode(value, validate=True)
    require(len(raw) == 64 and b64(raw) == value, "Invalid signature encoding")
    return raw


def openssl(*args, data=None):
    exe = (Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Git/usr/bin/openssl.exe"
           if os.name == "nt" else shutil.which("openssl"))
    require(exe and Path(exe).is_file(), "OpenSSL 3 or newer is required")
    result = subprocess.run([exe, *args], input=data, capture_output=True)
    require(result.returncode == 0, "Ed25519 signature/key verification failed")
    return result.stdout


def verify(path, value, temp):
    pub = temp / "public.der"
    sig = temp / "signature.bin"
    pub.write_bytes(SPKI_PREFIX + public_key())
    sig.write_bytes(signature_bytes(value))
    openssl("pkeyutl", "-verify", "-pubin", "-inkey", pub, "-keyform", "DER",
            "-rawin", "-in", path, "-sigfile", sig)


class SecureRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, url):
        require(urlsplit(url).scheme == "https", "Refused insecure download redirect")
        return super().redirect_request(req, fp, code, msg, headers, url)


def request(path, *, token=None):
    req = Request(f"https://api.github.com/repos/{REPO}/{path}", headers={
        "Accept": "application/vnd.github+json", "User-Agent": "TNote-release",
        "X-GitHub-Api-Version": "2022-11-28"})
    if token:
        # The storage host following GitHub's 302 must never receive this token.
        req.add_unredirected_header("Authorization", f"Bearer {token}")
    return build_opener(SecureRedirect).open(req, timeout=90)


def api(path, token=None):
    with request(path, token=token) as resp:
        data = resp.read(2_000_001)
    require(len(data) <= 2_000_000, "Oversize API response")
    return json.loads(data)


def digest(path):
    with path.open("rb") as data:
        return hashlib.file_digest(data, "sha256").hexdigest()


def candidate(run_id, commit, *, token=None):
    require(type(run_id) is int and run_id > 0, "Invalid candidate run")
    run = api(f"actions/runs/{run_id}", token)
    require(run.get("id") == run_id and run.get("event") == "push"
            and run.get("status") == "completed" and run.get("conclusion") == "success"
            and run.get("path") == WORKFLOW and run.get("head_sha") == commit
            and run.get("head_branch", "").startswith("candidate/")
            and run.get("repository", {}).get("full_name") == REPO
            and run.get("head_repository", {}).get("full_name") == REPO,
            "Expected a successful same-repository candidate push at this exact commit")
    workflow = api("actions/workflows/release.yml", token)
    require(workflow.get("path") == WORKFLOW and workflow.get("id") == run["workflow_id"],
            "Unexpected workflow")
    artifacts = api(f"actions/runs/{run_id}/artifacts?per_page=100", token)
    records = [a for a in artifacts["artifacts"] if a["name"] == "macos-release"]
    require(artifacts["total_count"] <= 100 and len(records) == 1, "Ambiguous candidate artifacts")
    a = records[0]
    origin = a.get("workflow_run", {})
    repo_id = run["repository"]["id"]
    require(a.get("expired") is False and type(a["id"]) is int and a["id"] > 0
            and origin.get("id") == run_id and origin.get("repository_id") == repo_id
            and origin.get("head_repository_id") == repo_id and origin.get("head_sha") == commit
            and re.fullmatch(r"sha256:[0-9a-f]{64}", a.get("digest", ""))
            and 0 < a["size_in_bytes"] <= MAX_ARCHIVE, "Unverified candidate artifact")
    return {"repository": REPO, "commit": commit, "run": run_id, "attempt": run["run_attempt"],
            "artifact": a["id"], "zip_sha256": a["digest"][7:], "zip_size": a["size_in_bytes"]}


def copy_archive(response, record, archive):
    with response, archive.open("xb") as out:
        remaining = record["zip_size"]
        while chunk := response.read(min(1 << 20, remaining + 1)):
            remaining -= len(chunk)
            require(remaining >= 0, "Oversize artifact archive")
            out.write(chunk)
    require(remaining == 0, "Incomplete artifact archive")


def download(record, archive, token):
    copy_archive(request(f"actions/artifacts/{record['artifact']}/zip", token=token), record, archive)


def download_with_gh(record, archive):
    # gh run download extracts the files and loses the exact signed ZIP bytes.
    executable = shutil.which("gh")
    require(executable, "認証済みのGitHub CLI、または --archive で公式候補ZIPを指定してください。")
    route = f"/repos/{REPO}/actions/artifacts/{record['artifact']}/zip"
    with subprocess.Popen([executable, "api", "--hostname", "github.com", route],
                          stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          env={**os.environ, "GH_PROMPT_DISABLED": "1"}) as process:
        try:
            copy_archive(process.stdout, record, archive)
            require(process.wait() == 0, "候補ZIPを取得できません。--archive で公式候補ZIPを指定してください。")
        except Exception:
            if process.poll() is None:
                process.kill()
            raise ValueError("認証済みのGitHub CLIで候補ZIPを取得できません。--archive で公式ZIPを指定してください。") from None


def provenance(info):
    version, build = version_info()
    require(info.get("CFBundleShortVersionString") == version
            and info.get("CFBundleVersion") == str(build)
            and info.get("SUFeedURL") == FEED_URL and info.get("SURequireSignedFeed") is True
            and info.get("SUVerifyUpdateBeforeExtraction") is True
            and info.get("SUPublicEDKey") == b64(public_key()), "Built application metadata mismatch")
    require(os.environ["GITHUB_REPOSITORY"] == REPO, "Unexpected repository")
    return {"repository": REPO, "commit": os.environ["GITHUB_SHA"],
            "run": int(os.environ["GITHUB_RUN_ID"]), "attempt": int(os.environ["GITHUB_RUN_ATTEMPT"]),
            "version": version, "build": build, "public_key": b64(public_key()),
            "minimum_macos": info["LSMinimumSystemVersion"]}


def extract_verified(record, archive, temp):
    require(archive.stat().st_size == record["zip_size"] and digest(archive) == record["zip_sha256"],
            "Archive differs from the digest published by GitHub")
    version, build = version_info()
    name = f"TNote-{version}.dmg"
    dmg = temp / name
    with ZipFile(archive) as z:
        require(sorted(z.namelist()) == sorted([name, "candidate-provenance.json"]),
                "Unexpected artifact members")
        require(0 < z.getinfo(name).file_size <= MAX_ARCHIVE
                and z.getinfo("candidate-provenance.json").file_size <= 4096, "Invalid artifact sizes")
        meta = json.loads(z.read("candidate-provenance.json"))
        expected = {k: record[k] for k in ("repository", "commit", "run", "attempt")}
        minimum = meta.get("minimum_macos")
        require(isinstance(minimum, str) and re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", minimum),
                "Invalid macOS deployment target")
        expected.update(version=version, build=build, public_key=b64(public_key()), minimum_macos=minimum)
        require(canonical(meta) == canonical(expected), "Candidate provenance does not match the app and run")
        with z.open(name) as src, dmg.open("xb") as dst:
            shutil.copyfileobj(src, dst)
    return {**record, "version": version, "build": build, "minimum_macos": minimum,
            "dmg_size": dmg.stat().st_size, "dmg_sha256": digest(dmg)}, dmg


def feed(record, dmg_sig):
    signature_bytes(dmg_sig)
    version, build = record["version"], record["build"]
    name = f"TNote-{version}.dmg"
    url = f"https://github.com/{REPO}/releases/download/v{version}/{name}"
    return (f'<?xml version="1.0" encoding="utf-8"?>\n'
            f'<rss version="2.0" xmlns:sparkle="{NS}"><channel>\n'
            f'<title>TNote</title><item><title>TNote {version}</title>\n'
            f'<sparkle:version>{build}</sparkle:version>\n'
            f'<sparkle:shortVersionString>{version}</sparkle:shortVersionString>\n'
            f'<sparkle:minimumSystemVersion>{record["minimum_macos"]}</sparkle:minimumSystemVersion>\n'
            f'<enclosure url="{url}" length="{record["dmg_size"]}" type="application/octet-stream" '
            f'sparkle:edSignature="{dmg_sig}"/>\n</item></channel></rss>\n').encode("utf-8")


def sealed_feed(content, signature):
    signature_bytes(signature)
    # Sparkle 2.10.1 common_cli/Signing.swift signAppcast().
    return content + f"<!-- sparkle-signatures:\nedSignature: {signature}\nlength: {len(content)}\n-->\n".encode()


def verify_release_feed(assets, temp):
    version, build = version_info()
    name = f"TNote-{version}.dmg"
    dmg, signed = assets / name, assets / "appcast.xml"
    require(0 < signed.stat().st_size <= 1024 * 1024, "Invalid appcast size")
    data = signed.read_bytes()
    content, marker, block = data.rpartition(b"<!-- sparkle-signatures:\n")
    match = re.fullmatch(rb"edSignature: ([A-Za-z0-9+/]{86}==)\nlength: ([0-9]+)\n-->\n", block)
    require(marker and match and int(match[2]) == len(content), "Invalid signed appcast length/block")
    body = temp / "feed-content.xml"
    body.write_bytes(content)
    verify(body, match[1].decode("ascii"), temp)
    items = ET.fromstring(content).findall("./channel/item")
    require(len(items) == 1, "Expected one stable release")
    item = items[0]
    enclosure = item.find("enclosure")
    require(item.findtext(f"{{{NS}}}version") == str(build)
            and item.findtext(f"{{{NS}}}shortVersionString") == version
            and enclosure is not None and enclosure.get("url") == f"https://github.com/{REPO}/releases/download/v{version}/{name}"
            and enclosure.get("length") == str(dmg.stat().st_size), "Unexpected update metadata")
    verify(dmg, enclosure.get(f"{{{NS}}}edSignature"), temp)


def tag_payload(tag):
    require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag), "Invalid release tag")
    ref = f"refs/tags/{tag}"
    if git("cat-file", "-t", ref).strip() != b"tag":
        return None
    require(int(git("cat-file", "-s", ref)) <= 32768, "Oversize release tag")
    message = git("cat-file", "tag", ref).split(b"\n\n", 1)[1]
    if not message.startswith(FORMAT.encode()):
        return None
    require(git("rev-parse", f"{ref}^{{commit}}") == git("rev-parse", "HEAD"),
            "Tag target differs from checked-out revision")
    header, _, raw = message.partition(b"\n\n")
    require(header == FORMAT.encode(), "Malformed candidate tag header")
    payload = json.loads(raw)
    require(raw == canonical(payload) + b"\n" and set(payload) == {"record", "dmg", "feed", "attestation"},
            "Malformed candidate tag payload")
    return payload


class Ed25519Signer:
    """Use Git for Windows' native OpenSSL 3 EVP API; private bytes stay in Python's process."""
    def __init__(self, private):
        require(len(private) == 48 and private.startswith(PKCS8_PREFIX),
                "The dedicated signing key is not Ed25519 PKCS8 DER")
        library = (Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Git/mingw64/bin/libcrypto-3-x64.dll"
                   if os.name == "nt" else ctypes.util.find_library("crypto"))
        require(library, "OpenSSL 3 libcrypto is required")
        self.crypto = ctypes.CDLL(str(library))
        ptr, size, string = ctypes.c_void_p, ctypes.c_size_t, ctypes.c_char_p
        length = ctypes.POINTER(size)
        for name, result, args in [
            ("EVP_PKEY_new_raw_private_key_ex", ptr, [ptr, string, string, ptr, size]),
            ("EVP_PKEY_get_raw_public_key", ctypes.c_int, [ptr, ptr, length]),
            ("EVP_PKEY_free", None, [ptr]), ("EVP_MD_CTX_new", ptr, []),
            ("EVP_MD_CTX_free", None, [ptr]),
            ("EVP_DigestSignInit", ctypes.c_int, [ptr, ptr, ptr, ptr, ptr]),
            ("EVP_DigestSign", ctypes.c_int, [ptr, ptr, length, ptr, size]),
        ]:
            fn = getattr(self.crypto, name)
            fn.argtypes, fn.restype = args, result
        self.key = self.crypto.EVP_PKEY_new_raw_private_key_ex(None, b"ED25519", None, private[16:], 32)
        require(self.key, "Invalid Ed25519 signing key")

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.crypto.EVP_PKEY_free(self.key)
        self.key = None

    def public(self):
        buf, length = ctypes.create_string_buffer(32), ctypes.c_size_t(32)
        require(self.crypto.EVP_PKEY_get_raw_public_key(self.key, buf, ctypes.byref(length)) == 1
                and length.value == 32, "Invalid Ed25519 public key")
        return buf.raw

    def sign(self, file):
        data = file.read_bytes()
        buf, length = ctypes.create_string_buffer(64), ctypes.c_size_t(64)
        ctx = self.crypto.EVP_MD_CTX_new()
        require(ctx, "Unable to open signing context")
        try:
            require(self.crypto.EVP_DigestSignInit(ctx, None, None, None, self.key) == 1 and
                    self.crypto.EVP_DigestSign(ctx, buf, ctypes.byref(length), data, len(data)) == 1
                    and length.value == 64, "Unable to sign update")
            return b64(buf.raw)
        finally:
            self.crypto.EVP_MD_CTX_free(ctx)


def checked_signer(path):
    require(os.name == "nt", "The release key belongs to a Windows DPAPI user")
    import win32crypt
    require(0 < path.stat().st_size <= 32768 and not path.resolve().is_relative_to(Path.cwd().resolve()),
            "Use the dedicated DPAPI key outside the repository")
    try:
        _, private = win32crypt.CryptUnprotectData(path.read_bytes(), None, None, None, 1)
    except Exception:
        raise ValueError("Unable to unlock the dedicated signing key for this user") from None
    return Ed25519Signer(private)


def attestation(payload):
    # Domain separate the attestation from appcast contents and DMG bytes.
    return FORMAT.encode() + b"\0" + canonical({k: payload[k] for k in ("record", "dmg", "feed")})


def prepare(args, temp):
    origin = git("remote", "get-url", "origin").decode().strip().removesuffix(".git")
    require(origin in (f"https://github.com/{REPO}", f"git@github.com:{REPO}",
                       f"ssh://git@github.com/{REPO}"), "Unexpected Git origin")
    require(not git("diff", "--name-only", "HEAD", "--", "pubspec.yaml", "macos/Runner/Info.plist",
                    "scripts/candidate_release.py", WORKFLOW).strip(), "Commit the release metadata and signer first")
    commit = git("rev-parse", "HEAD").decode().strip()
    record = candidate(args.run, commit)
    # Take a private snapshot before validation. The downloaded ZIP can be in
    # a synced folder and may change independently of this signing operation.
    snapshot = temp / "candidate.zip"
    if args.archive:
        require(args.archive.stat().st_size == record["zip_size"], "Archive size mismatch")
        copy_archive(args.archive.open("rb"), record, snapshot)
    else:
        download_with_gh(record, snapshot)
    record, dmg = extract_verified(record, snapshot, temp)
    with checked_signer(args.key) as signer:
        require(signer.public() == public_key(), "The key does not match SUPublicEDKey")
        payload = {"record": record, "dmg": signer.sign(dmg)}
        verify(dmg, payload["dmg"], temp)
        appcast = temp / "appcast-content.xml"
        appcast.write_bytes(feed(record, payload["dmg"]))
        payload["feed"] = signer.sign(appcast)
        verify(appcast, payload["feed"], temp)
        body = temp / "attestation.bin"
        body.write_bytes(attestation(payload))
        payload["attestation"] = signer.sign(body)
        verify(body, payload["attestation"], temp)
    message = FORMAT.encode() + b"\n\n" + canonical(payload) + b"\n"
    if args.output:
        with args.output.open("xb") as dest:
            dest.write(message)
    if args.create_tag:
        git("tag", "--annotate", "--no-sign", "--cleanup=verbatim", "--file=-", f"v{record['version']}", commit, data=message)


def promote(args, temp):
    payload = tag_payload(args.tag)
    require(payload and args.tag == f"v{version_info()[0]}", "Missing candidate tag or version mismatch")
    body = temp / "attestation.bin"
    body.write_bytes(attestation(payload))
    verify(body, payload["attestation"], temp)
    token = os.environ["GITHUB_TOKEN"]
    record = candidate(payload["record"]["run"], git("rev-parse", "HEAD").decode().strip(), token=token)
    archive = temp / "candidate.zip"
    download(record, archive, token)
    record, dmg = extract_verified(record, archive, temp)
    require(canonical(record) == canonical(payload["record"]), "Candidate metadata has changed")
    verify(dmg, payload["dmg"], temp)
    content = feed(record, payload["dmg"])
    appcast = temp / "appcast-content.xml"
    appcast.write_bytes(content)
    verify(appcast, payload["feed"], temp)
    args.assets.mkdir(parents=True, exist_ok=True)
    with (args.assets / "appcast.xml").open("xb") as out:
        out.write(sealed_feed(content, payload["feed"]))
    with (args.assets / dmg.name).open("xb") as out, dmg.open("rb") as data:
        shutil.copyfileobj(data, out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    mode = sub.add_parser("mode")
    mode.add_argument("--tag", required=True)
    sign = sub.add_parser("prepare")
    sign.add_argument("--run", type=int, required=True)
    sign.add_argument("--archive", type=Path, help="official Actions ZIP, defaults to downloading with an already authenticated gh")
    sign.add_argument("--key", type=Path, required=True)
    sign.add_argument("--output", type=Path)
    sign.add_argument("--create-tag", action="store_true")
    sign.add_argument("--push-tag", action="store_true", help="ask before pushing the newly created tag")
    copy = sub.add_parser("promote")
    copy.add_argument("--tag", required=True)
    copy.add_argument("--assets", type=Path, required=True)
    verify_feed = sub.add_parser("verify-feed")
    verify_feed.add_argument("--assets", type=Path, required=True)
    prove = sub.add_parser("provenance")
    prove.add_argument("--plist", type=Path, required=True)
    prove.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.cmd == "mode":
        print("candidate" if tag_payload(args.tag) is not None else "secret")
    elif args.cmd == "provenance":
        meta = provenance(plistlib.loads(args.plist.read_bytes()))
        with args.output.open("xb") as out:
            out.write(canonical(meta))
    else:
        with TemporaryDirectory(prefix="tnote-candidate-") as scratch:
            if args.cmd == "prepare":
                require(args.output or args.create_tag, "Specify --output or --create-tag")
                require(not args.push_tag or args.create_tag, "--push-tag requires --create-tag")
                prepare(args, Path(scratch))
                if args.push_tag:
                    tag = f"v{version_info()[0]}"
                    answer = input(f"{tag} を {REPO} に送信して正式公開を開始しますか？（はい／いいえ） ")
                    if answer.strip() == "はい":
                        git("push", "origin", f"refs/tags/{tag}")
                    else:
                        print(f"タグ {tag} を端末に保存しました。")
            elif args.cmd == "verify-feed":
                verify_release_feed(args.assets, Path(scratch))
            else:
                promote(args, Path(scratch))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        sys.exit(f"Release verification failed: {exc}")
