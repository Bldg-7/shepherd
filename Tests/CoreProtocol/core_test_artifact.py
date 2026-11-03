"""Explicit test-only core artifact selection; never installs an executable.

The official archive pin remains strict. A source backport is a separate opt-in
mode, requires the checked-in recipe and a successful local build receipt, and
is always labeled NOT an official release. Receipts/checksums are not signatures
or permission to trust an arbitrary third-party artifact.
"""
from pathlib import Path
import hashlib
import json
import tarfile

HERE = Path(__file__).resolve().parent
OFFICIAL_SHA256 = "698d8f0c44f4e4b15fec174d52a39d57a014cfd71added44b53a0753b469d0fd"
# Independently selected, not a replacement of the retained 0.1.16 control.
# https://releases.herdr.dev/core/0.1.17/manifest.json (macos-aarch64)
OFFICIAL_017_SHA256 = "cedbd4d4d9ba1385588198dd4d3c67d2654478f33add5b6445d4d0eb9da5fcf3"
RECIPE = HERE / "backport/recipe.json"
CHECKS = {"formatter-format", "formatter-tests", "core-build", "rust-vt-tests", "rust-core-unit-tests"}


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        while block := stream.read(1 << 20): h.update(block)
    return h.hexdigest()


def add_arguments(parser):
    choice = parser.add_mutually_exclusive_group(required=True)
    choice.add_argument("--archive", type=Path, help="official 0.1.16 ARM64 archive (fixed checksum)")
    choice.add_argument("--official-017-archive", type=Path, help="official 0.1.17 ARM64 archive (separate fixed checksum)")
    choice.add_argument("--build-receipt", type=Path, help="explicit locally qualified backport build receipt")
    return choice


def select(archive=None, build_receipt=None, *, official_017_archive=None):
    if sum(v is not None for v in (archive, build_receipt, official_017_archive)) != 1:
        raise ValueError("select exactly one artifact mode")
    if official_017_archive is not None:
        return {"archive": Path(official_017_archive).resolve(), "archiveSHA256": OFFICIAL_017_SHA256,
                "version": "0.1.17", "variant": "official-0.1.17", "officialRelease": True,
                "resizeNotifications": True}
    if archive is not None:
        return {"archive": Path(archive).resolve(), "archiveSHA256": OFFICIAL_SHA256,
                "version": "0.1.16", "variant": "official-0.1.16", "officialRelease": True}
    path = Path(build_receipt).resolve()
    receipt = json.loads(path.read_text())
    recipe = json.loads(RECIPE.read_text())
    if receipt.get("schema") != 1 or receipt.get("variant") != recipe["id"] or receipt.get("officialRelease") is not False:
        raise ValueError("not a supported source-backport receipt")
    if receipt.get("recipeSHA256") != digest(RECIPE): raise ValueError("recipe changed since build")
    if receipt.get("buildScriptSHA256") != digest(HERE / "backport/build-backport.py"):
        raise ValueError("build procedure changed since qualification")
    for field in ("version", "coreCommit", "ghosttyCommit", "upstreamCommit", "patchSHA256", "patchedFormatterSHA256", "cargoLockSHA256"):
        if receipt.get(field) != recipe[field]: raise ValueError("receipt differs from recipe: " + field)
    if digest(HERE / "backport" / recipe["patchFile"]) != recipe["patchSHA256"]:
        raise ValueError("backport patch changed")
    if set(receipt.get("checks", {})) != CHECKS or not all(receipt["checks"][c].get("passed") is True for c in CHECKS):
        raise ValueError("build/test qualification incomplete")
    for stage in ("formatter-tests", "rust-vt-tests", "rust-core-unit-tests"):
        count = receipt["checks"][stage].get("testCount")
        if type(count) is not int or count < 1: raise ValueError("zero/missing test coverage: " + stage)
    tools = receipt.get("toolchain", {})
    if tools.get("zig") != recipe["zigVersion"] or tools.get("zigSHA256") != recipe["zigBinarySHA256"]:
        raise ValueError("unqualified Zig toolchain")
    if not tools.get("rustc", "").startswith("rustc 1.95.0 "): raise ValueError("unqualified Rust toolchain")
    if receipt.get("archive") != recipe["archiveName"]: raise ValueError("unexpected archive name")
    selected = path.parent / recipe["archiveName"]
    if selected.is_symlink() or selected.resolve().parent != path.parent: raise ValueError("archive must stay beside receipt")
    for field in ("archiveSHA256", "binarySHA256"):
        h = receipt.get(field, "")
        if len(h) != 64 or any(c not in "0123456789abcdef" for c in h): raise ValueError("invalid digest")
    # Check consistency with retained logs. This does not authenticate a
    # third-party receipt; only explicitly trusted local builds may be run.
    for name in CHECKS:
        if digest(path.parent / (name + ".log")) != receipt["checks"][name].get("logSHA256"):
            raise ValueError("build log changed: " + name)
    return {"archive": selected, "archiveSHA256": receipt["archiveSHA256"],
            "binarySHA256": receipt["binarySHA256"], "version": receipt["version"],
            "variant": receipt["variant"], "officialRelease": False,
            "recipeSHA256": receipt["recipeSHA256"], "buildReceipt": receipt}


def extract(artifact, destination):
    destination = Path(destination)
    # Hash and extract through the same open file, never re-open a different
    # inode after validation. Only one bounded, regular archive member is used.
    archive = artifact["archive"]
    if not archive.is_file() or archive.stat().st_size > 256 << 20:
        raise ValueError("expected a bounded regular archive")
    with archive.open("rb") as stream:
        h = hashlib.sha256()
        while block := stream.read(1 << 20): h.update(block)
        if h.hexdigest() != artifact["archiveSHA256"]: raise ValueError("archive checksum mismatch")
        stream.seek(0)
        allowed = {"herdr-core", "LICENSE", "THIRD-PARTY-NOTICES", "GHOSTTY-LICENSE", "BACKPORT.patch", "SOURCE-PROVENANCE.json"}
        seen = set(); created = False
        try:
            with tarfile.open(fileobj=stream, mode="r|gz") as package:
                for member in package:
                    if member.name not in allowed or member.name in seen or not member.isfile():
                        raise ValueError("unexpected/duplicate/non-regular archive member")
                    seen.add(member.name)
                    limit = 128 << 20 if member.name == "herdr-core" else 8 << 20
                    if not 0 <= member.size <= limit: raise ValueError("oversized archive member")
                    if member.name != "herdr-core": continue
                    if member.size == 0: raise ValueError("empty executable")
                    with package.extractfile(member) as source, destination.open("xb") as output:
                        created = True
                        while block := source.read(1 << 20): output.write(block)
            if not created: raise ValueError("archive has no executable")
        except BaseException:
            if created: destination.unlink(missing_ok=True)
            raise
    if "binarySHA256" in artifact and digest(destination) != artifact["binarySHA256"]:
        destination.unlink()
        raise ValueError("binary differs from build receipt")
    destination.chmod(0o700)
    return {**{k: v for k, v in artifact.items() if k != "archive"}, "binarySHA256": digest(destination),
            "independentSignatureVerified": False}
