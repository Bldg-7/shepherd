#!/usr/bin/env python3
"""Offline integrity gates for the macOS third-party-notice release inputs.

The frozen inventory is the source of attribution provenance.  This runner only
reads local files: it never builds, resolves packages, starts an app, or uses
the network.  ``--products`` accepts both an archive and its DerivedData
because an xcarchive contains the exported product but not the static-package
object evidence needed to prove the linked-product set.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import tempfile
from typing import Iterable

ROOT = Path(__file__).resolve().parents[2]
INVENTORY_PATH = ROOT / "Tests/Notices/inventory.json"
SEP = "========================================================================"
REMOTE_REVISIONS = {
    "bigint": "e07e00fa1fd435143a2dcf8b7eec9a7710b2fdfe",
    "sparkle": "eef1a539a373c1f1a320624b1130fc5de7b2e100",
    "swift-argument-parser": "6a52f3251125d74daf04fcbd5e6f08a75d074382",
    "swift-asn1": "3b6410f7dee09eb33cdd26260c5fd47fda19b0e2",
    "swift-atomics": "0442cb5a3f98ab802acb777929fdb446bda11a34",
    "swift-certificates": "f4cd9e78a1ec209b27e426a5f5c693675f95e75a",
    "swift-collections": "98ef3c98609a1e31b7e157b5b619579001a789d6",
    "swift-crypto": "95ba0316a9b733e92bb6b071255ff46263bbe7dc",
    "swift-log": "9c6fb14227f55d8f711ce3847dc2f419fb0ecacb",
    "swift-nio": "21de5f08c1a166a6dd293d0e587ad977bf8dac5d",
    "swift-nio-ssl": "173cc69a058623525a58ae6710e2f5727c663793",
    "swift-system": "869129b7bf4ecc57b97d0193ad29690ca2134750",
    "swiftterm": "5d14406844143538cd8f8851d2d8a67c1fe443e5",
}
# These names are intentionally build-output evidence, not a guessed archive
# layout.  Frameworks are found in an app/archive; static Swift products are
# found in DerivedData object/module output.
PRODUCT_EVIDENCE = {
    "BigInt": ("BigInt",),
    "Sparkle": ("Sparkle.framework",),
    "swift-atomics": ("Atomics",),
    "swift-asn1": ("SwiftASN1",),
    "swift-certificates": ("X509",),
    "swift-collections": ("DequeModule",),
    "swift-crypto": ("Crypto", "CCryptoBoringSSL"),
    "swift-log": ("Logging",),
    "swift-nio": ("NIOCore",),
    "swift-nio-ssl": ("NIOSSL", "CNIOBoringSSL"),
    "SwiftTerm": ("SwiftTerm",),
    "Citadel": ("Citadel", "CCitadelBcrypt"),
    "swift-nio-ssh": ("NIOSSH",),
    "CEF": ("Chromium Embedded Framework.framework",),
    "AgentProxy": ("AgentProxyProtocol",),
}


class NoticeFailure(RuntimeError):
    pass


def fail(message: str) -> None:
    raise NoticeFailure(message)


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read JSON {path}: {error}")


def sha256(path: Path) -> str:
    if not path.is_file():
        fail(f"required file is missing: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_hash(path: Path, expected: str, label: str) -> None:
    actual = sha256(path)
    if actual != expected:
        fail(f"{label} SHA-256 is {actual}, not frozen {expected}")


def newline_count(path: Path) -> int:
    if not path.is_file():
        fail(f"required file is missing: {path}")
    total = 0
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            total += chunk.count(b"\n")
    return total


def notice_section(text: str, title: str) -> str:
    marker = f"{SEP}\n{title}\n{SEP}\n"
    if text.count(marker) != 1:
        fail(f"notice section must occur exactly once: {title}")
    start = text.index(marker) + len(marker)
    end = text.find(f"\n\n{SEP}\n", start)
    return (text[start:] if end == -1 else text[start:end]).rstrip("\n")


def normalized_lines(path: Path, start: int | None = None, end: int | None = None) -> str:
    lines = path.read_text(encoding="utf-8").splitlines()
    if start is not None:
        lines = lines[start:end]
    return "\n".join(line.rstrip(" \t") for line in lines).rstrip("\n")


def load_inventory() -> dict:
    inventory = read_json(INVENTORY_PATH)
    if inventory.get("schema") != "shepherd.third-party-notices.inventory/v1":
        fail("unexpected third-party notice inventory schema")
    if inventory.get("schemaStatus") != "frozen-for-package-and-gate-integration":
        fail("notice inventory is not frozen for gate integration")
    return inventory


def check_notice_structure(inventory: dict, mac: str, ios: str) -> None:
    if not re.match(r"^Third-party notices for hrdrhrdrhrdr [0-9]+(?:\.[0-9]+){1,2}\n", mac):
        fail("macOS notice has no valid version header")
    for name, text in (("macOS", mac), ("iOS", ios)):
        headings = re.findall(rf"(?m)^{re.escape(SEP)}\n(.+)\n{re.escape(SEP)}$", text)
        if not headings:
            fail(f"{name} notice has no separator-delimited sections")
        if len(headings) != len(set(headings)):
            fail(f"{name} notice has duplicate section titles")
    invariant = inventory["sectionInvariants"]
    if mac.count(invariant["zstandardSection"]) != invariant["zstandardCount"]:
        fail("AgentProxy Zstandard notice is missing or duplicated")
    trademarks = f"{SEP}\n{invariant['trademarksSection']}\n{SEP}"
    if mac.count(trademarks) != 1:
        fail("macOS Trademarks section is missing or duplicated")
    if invariant["trademarksFinal"] and not mac.rstrip().endswith(
        "hrdrhrdrhrdr is not affiliated with or endorsed by them."
    ):
        fail("macOS Trademarks section is not final")
    if mac.count("CCryptoBoringSSL (BoringSSL)") != 1 or mac.count("CNIOBoringSSL (BoringSSL)") != 1:
        fail("the two distinct BoringSSL sections are not unique")


def check_notice_sources(inventory: dict, mac: str, ios: str) -> None:
    for block in inventory["verbatimBlocks"]:
        source = ROOT / block["sourcePath"]
        require_hash(source, block["sha256"], block["section"])
    for block in inventory["verbatimBlocks"][:6]:
        title = block["sourcePath"]
        if notice_section(mac, title) != normalized_lines(ROOT / title):
            fail(f"notice does not exactly match normalized source: {title}")
    boring = inventory["verbatimBlocks"][6]
    boring_title = "build/SourcePackages/checkouts/swift-nio-ssl/Sources/CNIOBoringSSL (BoringSSL)"
    if not notice_section(mac, boring_title).endswith(normalized_lines(ROOT / boring["sourcePath"])):
        fail("swift-nio-ssl BoringSSL notice does not end with the pinned fixture")
    ushet = inventory["verbatimBlocks"][7]
    ushet_title = "uSHET c09e0acafd86720efe42dc15c63e0cc228244c32 LICENSE (cpp_magic.h)"
    expected_ushet = "\n".join((ROOT / ushet["sourcePath"]).read_text(encoding="utf-8").splitlines()[:22])
    if notice_section(mac, ushet_title) != expected_ushet or notice_section(ios, ushet_title) != expected_ushet:
        fail("uSHET macOS/iOS parity block does not exactly match frozen source")
    for block in inventory["sourceHeaderBlocks"]:
        source_paths = block["sourcePath"].split(" and ")
        if len(source_paths) == 2 and "/" not in source_paths[1]:
            source_paths[1] = str(Path(source_paths[0]).with_name(source_paths[1]))
        for source_path, expected_hash in zip(source_paths, block["sha256"].split("; ")):
            require_hash(ROOT / source_path, expected_hash, block["section"])
    sha_title = "build/SourcePackages/checkouts/swift-nio/Sources/CNIOSHA1/c_nio_sha1.c:10-38 (FreeBSD SHA-1)"
    if notice_section(mac, sha_title) != normalized_lines(ROOT / inventory["sourceHeaderBlocks"][0]["sourcePath"], 9, 38):
        fail("FreeBSD SHA-1 notice is not the frozen source header")
    musl_title = "build/SourcePackages/checkouts/swift-certificates/Sources/X509/X509BaseTypes/TimeCalculations.swift:22-45 (musl)"
    if notice_section(mac, musl_title) != normalized_lines(ROOT / inventory["sourceHeaderBlocks"][1]["sourcePath"], 21, 45):
        fail("musl notice is not the frozen source header")
    for title in (
        "Vendor/Citadel/Sources/CCitadelBcrypt/bcrypt.c (ISC)",
        "Vendor/Citadel/Sources/CCitadelBcrypt/blf.c and blf.h (BSD advertising clause)",
    ):
        notice_section(mac, title)


def check_dependency_graph(inventory: dict) -> None:
    resolved = read_json(ROOT / inventory["changeFingerprints"]["packageResolved"])
    pins = {pin["identity"].lower(): pin["state"]["revision"] for pin in resolved.get("pins", [])}
    if pins != REMOTE_REVISIONS:
        missing = sorted(set(REMOTE_REVISIONS) - set(pins))
        extra = sorted(set(pins) - set(REMOTE_REVISIONS))
        changed = sorted(name for name in set(pins) & set(REMOTE_REVISIONS) if pins[name] != REMOTE_REVISIONS[name])
        fail(f"Package.resolved drift (missing={missing}, extra={extra}, changed={changed})")
    project = (ROOT / inventory["changeFingerprints"]["productGraph"]).read_text(encoding="utf-8")
    required_products = ("NIOSSL", "X509", "NIOCore", "NIOPosix", "NIOHTTP1", "NIOWebSocket", "Citadel", "SwiftTerm", "Sparkle")
    for product in required_products:
        if f"productName = {product};" not in project:
            fail(f"project is missing linked package product {product}")
    manifest = (ROOT / inventory["changeFingerprints"]["localAgentProxy"]).read_text(encoding="utf-8")
    for product in ("AgentProxyProtocol", "AgentProxyForwarder"):
        if f'.library(name: "{product}"' not in manifest or f"productName = {product};" not in project:
            fail(f"local AgentProxy product graph drifted: {product}")
    linked = {entry["identity"] for entry in inventory["linkedOrRetainedUnlinked"] if entry["status"].startswith("linked")}
    if set(PRODUCT_EVIDENCE) != linked:
        fail("gate product evidence mapping no longer matches frozen linked inventory")


def package_records(lockfile: Path) -> dict[str, dict]:
    lock = read_json(lockfile)
    packages = lock.get("packages")
    if not isinstance(packages, dict):
        fail(f"runtime lockfile has no packages object: {lockfile}")
    records = {name: record for name, record in packages.items() if name.startswith("node_modules/")}
    if not records:
        fail("runtime lockfile has no installed package identities")
    return records


def license_file(package_dir: Path) -> Path | None:
    for name in ("LICENSE", "LICENSE.txt", "LICENSE.md", "COPYING", "NOTICE"):
        candidate = package_dir / name
        if candidate.is_file():
            return candidate
    return None


def check_runtime_packages(inventory: dict, runtime_root: Path | None = None) -> None:
    metadata = inventory["runtimePackageLicenseMetadata"]
    source_runtime = ROOT / metadata["lockfile"]
    runtime = runtime_root or source_runtime.parent
    lockfile = runtime / "package-lock.json"
    records = package_records(lockfile)
    installed = runtime / "node_modules"
    actual_records: dict[str, Path] = {}
    if installed.is_dir():
        for package_json in installed.rglob("package.json"):
            package_dir = package_json.parent
            relative = package_dir.relative_to(runtime).as_posix()
            actual_records[relative] = package_dir
    if set(records) != set(actual_records):
        fail(f"runtime package-lock/node_modules drift (lock={sorted(records)}, installed={sorted(actual_records)})")
    for identity, record in records.items():
        package = read_json(actual_records[identity] / "package.json")
        if package.get("version") != record.get("version"):
            fail(f"runtime package version differs from lockfile: {identity}")
        if license_file(actual_records[identity]) is None:
            fail(f"runtime package has no bundled top-level license file: {identity}")
    mac = (ROOT / inventory["noticeFiles"]["macOS"]).read_text(encoding="utf-8")
    if metadata["noticeSection"] not in mac:
        fail("macOS notice has no Playwright bundled-license location attribution")


def check_cef(inventory: dict, require_stage: bool = True) -> None:
    credits = inventory["cefCredits"]
    script = (ROOT / inventory["changeFingerprints"]["cefConstants"]).read_text(encoding="utf-8")
    for name, value in (("CEF_VERSION", credits["version"]), ("CREDITS_BYTES", credits["bytes"]), ("CREDITS_NEWLINES", credits["newlines"]), ("CREDITS_SHA256", credits["sha256"])):
        if not re.search(rf"^{name}=['\"]?{re.escape(str(value))}['\"]?$", script, re.MULTILINE):
            fail(f"scripts/cef.sh {name} differs from frozen CEF provenance")
    source = ROOT / credits["sourcePath"]
    if source.stat().st_size != credits["bytes"]:
        fail("pinned CEF credits byte count differs from inventory")
    if newline_count(source) != credits["newlines"]:
        fail("pinned CEF credits newline count differs from inventory")
    require_hash(source, credits["sha256"], "pinned CEF credits")
    readme = source.parent / "README.txt"
    if not readme.is_file() or "CREDITS.html" not in readme.read_text(encoding="utf-8", errors="replace"):
        fail("pinned CEF README does not identify CREDITS.html provenance")
    if require_stage:
        staged = ROOT / "Vendor/CEF/out/ChromiumCredits.html"
        if staged.stat().st_size != credits["bytes"]:
            fail("staged Chromium credits byte count differs from inventory")
        require_hash(staged, credits["sha256"], "staged Chromium credits")


def check_source() -> dict:
    inventory = load_inventory()
    mac = (ROOT / inventory["noticeFiles"]["macOS"]).read_text(encoding="utf-8")
    ios = (ROOT / inventory["noticeFiles"]["iOS"]).read_text(encoding="utf-8")
    check_notice_structure(inventory, mac, ios)
    check_notice_sources(inventory, mac, ios)
    check_dependency_graph(inventory)
    check_runtime_packages(inventory)
    check_cef(inventory)
    return inventory


def check_app(inventory: dict, app: Path) -> None:
    if not app.is_dir() or app.suffix != ".app":
        fail(f"--app requires an existing .app bundle: {app}")
    info_path = app / "Contents/Info.plist"
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"cannot read app Info.plist: {error}")
    source_notice = ROOT / inventory["noticeFiles"]["macOS"]
    bundled_notice = app / "Contents/Resources/ThirdPartyNotices.txt"
    if not bundled_notice.is_file() or bundled_notice.read_bytes() != source_notice.read_bytes():
        fail("app ThirdPartyNotices.txt does not byte-match the current macOS source notice")
    version = re.match(r"Third-party notices for hrdrhrdrhrdr ([0-9]+(?:\.[0-9]+){1,2})\n", source_notice.read_text(encoding="utf-8"))
    if version is None or info.get("CFBundleShortVersionString") != version.group(1):
        fail("app notice header version does not match CFBundleShortVersionString")
    credits = app / inventory["cefCredits"]["resourcePath"]
    require_hash(credits, inventory["cefCredits"]["sha256"], "app Chromium credits")
    runtime = app / "Contents/Resources/AgentRuntime"
    if not runtime.is_dir():
        fail("app has no bundled AgentRuntime resource")
    source_lock = ROOT / inventory["runtimePackageLicenseMetadata"]["lockfile"]
    if (runtime / "package-lock.json").read_bytes() != source_lock.read_bytes():
        fail("app runtime package-lock differs from source lockfile")
    check_runtime_packages(inventory, runtime)


def evidence_paths(inputs: Iterable[Path]) -> list[str]:
    paths: list[str] = []
    for input_path in inputs:
        if not input_path.exists():
            fail(f"--products input does not exist: {input_path}")
        if input_path.is_file():
            paths.append(input_path.name)
            continue
        for path in input_path.rglob("*"):
            if path.name.endswith((".o", ".framework", ".app")) or path.is_dir() and path.name.endswith((".framework", ".app")):
                paths.append(path.as_posix())
    if not paths:
        fail("--products found no .o, .framework, or .app evidence; supply the archive plus its DerivedData, not an empty layout")
    return paths


def check_products(inventory: dict, inputs: list[Path]) -> None:
    paths = evidence_paths(inputs)
    joined = "\n".join(paths)
    for identity, names in PRODUCT_EVIDENCE.items():
        if not all(name in joined for name in names):
            fail(f"linked product evidence is unavailable for {identity}: expected {names}; archive alone has no static .o evidence, include DerivedData")


def stamp_version(version: str) -> None:
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", version):
        fail(f"invalid notice version: {version}")
    path = ROOT / "Shepherd/ThirdPartyNotices.txt"
    text = path.read_text(encoding="utf-8")
    updated, count = re.subn(r"\AThird-party notices for hrdrhrdrhrdr [0-9]+(?:\.[0-9]+){1,2}", f"Third-party notices for hrdrhrdrhrdr {version}", text)
    if count != 1:
        fail("cannot stamp an unrecognized macOS notice header")
    path.write_text(updated, encoding="utf-8")


def copy_runtime_for_fixture(destination: Path) -> None:
    source = ROOT / "Shepherd/Agents/AgentRuntime"
    shutil.copytree(source, destination, ignore=shutil.ignore_patterns(".DS_Store"))


def self_test() -> None:
    inventory = check_source()
    mac = (ROOT / inventory["noticeFiles"]["macOS"]).read_text(encoding="utf-8")
    ios = (ROOT / inventory["noticeFiles"]["iOS"]).read_text(encoding="utf-8")

    def rejected(label: str, action) -> None:
        try:
            action()
        except NoticeFailure:
            print(f"self-test: {label}: rejected")
            return
        raise NoticeFailure(f"self-test failed: {label} was accepted")

    rejected("format", lambda: check_notice_structure(inventory, "broken\n", ios))
    rejected("duplicate section", lambda: check_notice_structure(inventory, mac + f"\n{SEP}\nTrademarks\n{SEP}\nextra\n", ios))
    rejected("source attribution hash", lambda: require_hash(ROOT / inventory["verbatimBlocks"][0]["sourcePath"], "0" * 64, "fixture"))
    rejected("CEF provenance", lambda: check_cef({**inventory, "cefCredits": {**inventory["cefCredits"], "sha256": "0" * 64}}))
    rejected("package pin drift", lambda: check_dependency_graph({**inventory, "changeFingerprints": {**inventory["changeFingerprints"], "packageResolved": "Tests/Notices/fixtures/missing.json"}}))
    rejected("runtime lock/license drift", lambda: check_runtime_packages(inventory, ROOT / "Tests/Notices/fixtures"))
    rejected("missing product evidence", lambda: check_products(inventory, [ROOT / "Tests/Notices/fixtures"]))

    with tempfile.TemporaryDirectory(prefix="shphrd-87-notices-") as temporary:
        fixture = Path(temporary)
        app = fixture / "fixture.app"
        resources = app / "Contents/Resources"
        resources.mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.6.0"}))
        shutil.copy2(ROOT / inventory["noticeFiles"]["macOS"], resources / "ThirdPartyNotices.txt")
        shutil.copy2(ROOT / inventory["cefCredits"]["sourcePath"], resources / "ChromiumCredits.html")
        copy_runtime_for_fixture(resources / "AgentRuntime")
        check_app(inventory, app)

        products = fixture / "products"
        products.mkdir()
        for names in PRODUCT_EVIDENCE.values():
            for name in names:
                evidence = products / (name if name.endswith(".framework") else f"{name}.o")
                if evidence.suffix == ".framework":
                    evidence.mkdir()
                else:
                    evidence.touch()
        check_products(inventory, [products])
        (products / "NIOSSH.o").unlink()
        rejected("incomplete product evidence", lambda: check_products(inventory, [products]))

        (resources / "ThirdPartyNotices.txt").write_text("stale\n", encoding="utf-8")
        rejected("app notice/version content mismatch", lambda: check_app(inventory, app))
        shutil.copy2(ROOT / inventory["noticeFiles"]["macOS"], resources / "ThirdPartyNotices.txt")
        (resources / "ChromiumCredits.html").write_text("stale\n", encoding="utf-8")
        rejected("app CEF credits hash", lambda: check_app(inventory, app))
    print("self-test: all negative guards rejected")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="exported macOS .app to validate")
    parser.add_argument("--products", type=Path, nargs="+", metavar="PATH", help="archive and DerivedData/product-evidence paths")
    parser.add_argument("--self-test", action="store_true", help="exercise synthetic failing guards")
    parser.add_argument("--stamp-version", metavar="VERSION", help="write the release version into the macOS notice header")
    args = parser.parse_args()
    try:
        if args.stamp_version:
            stamp_version(args.stamp_version)
        if args.self_test:
            self_test()
            return 0
        inventory = check_source()
        if args.app:
            check_app(inventory, args.app)
        if args.products:
            check_products(inventory, args.products)
    except NoticeFailure as error:
        print(f"error: {error}", file=os.sys.stderr)
        return 1
    print("Third-party notice gate passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
