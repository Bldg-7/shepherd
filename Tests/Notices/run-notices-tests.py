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
import subprocess
import sys
import tempfile
from typing import Iterable

ROOT = Path(__file__).resolve().parents[2]
INVENTORY_PATH = ROOT / "Tests/Notices/inventory.json"
SEP = "========================================================================"
# The reviewed remote package pins.  SwiftTerm is vendored (Vendor/SwiftTerm),
# and swift-argument-parser and swift-certificates are no longer resolved.
REMOTE_REVISIONS = {
    "bigint": "e07e00fa1fd435143a2dcf8b7eec9a7710b2fdfe",
    "sparkle": "eef1a539a373c1f1a320624b1130fc5de7b2e100",
    "swift-asn1": "3b6410f7dee09eb33cdd26260c5fd47fda19b0e2",
    "swift-atomics": "0442cb5a3f98ab802acb777929fdb446bda11a34",
    "swift-collections": "98ef3c98609a1e31b7e157b5b619579001a789d6",
    "swift-crypto": "95ba0316a9b733e92bb6b071255ff46263bbe7dc",
    "swift-log": "9c6fb14227f55d8f711ce3847dc2f419fb0ecacb",
    "swift-nio": "21de5f08c1a166a6dd293d0e587ad977bf8dac5d",
    "swift-nio-ssl": "173cc69a058623525a58ae6710e2f5727c663793",
    "swift-system": "869129b7bf4ecc57b97d0193ad29690ca2134750",
}
# Each static product is checked as an exact, non-empty Mach-O input in the
# Xcode-generated link-file-list of the app target.  These are deliberately not
# filename-search tokens: the expected path is derived from the supplied
# Release DerivedData root and configuration.  The keys are the inventory's
# "linked" identities (Sparkle is checked as the embedded framework instead).
STATIC_PRODUCT_EVIDENCE = {
    "BigInt": ("BigInt.o",),
    "swift-atomics": ("Atomics.o",),
    "swift-asn1": ("SwiftASN1.o",),
    "swift-collections": ("DequeModule.o",),
    "swift-crypto": ("Crypto.o", "CCryptoBoringSSL.o"),
    "swift-log": ("Logging.o",),
    "swift-nio": ("NIOCore.o",),
    "SwiftTerm": ("SwiftTerm.o",),
    "Citadel": ("Citadel.o", "CCitadelBcrypt.o"),
    "swift-nio-ssh": ("NIOSSH.o",),
    # The archive readers' codecs and protocol; the capture forwarder is not linked.
    "AgentProxy": ("AgentProxyCore.o", "AgentProxyProtocol.o"),
}
# Built products the Release archive must not contain: the retired capture
# forwarder/helper, the removed fixture SDK/app and the browser's TLS/HTTP stack.
RETIRED_RELEASE_PRODUCTS = ("AgentProxyForwarder.o", "hrdrhrdrhrdr-agent-proxy", "ShepherdLegacyFixtures.o",
                            "ShepherdLegacyFixtures.app", "NIOSSL.o", "CNIOBoringSSL.o", "X509.o", "NIOHTTP1.o",
                            "NIOWebSocket.o")


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
    blocks = {block["section"]: block for block in inventory["verbatimBlocks"]}
    for block in inventory["verbatimBlocks"]:
        if not block["section"].endswith(" NOTICE"):
            continue
        title = block["sourcePath"]
        if notice_section(mac, title) != normalized_lines(ROOT / title):
            fail(f"notice does not exactly match normalized source: {title}")
    boring = blocks["BoringSSL 817ab07 LICENSE"]
    boring_title = "build/SourcePackages/checkouts/swift-nio-ssl/Sources/CNIOBoringSSL (BoringSSL)"
    if not notice_section(mac, boring_title).endswith(normalized_lines(ROOT / boring["sourcePath"])):
        fail("swift-nio-ssl BoringSSL notice does not end with the pinned fixture")
    ushet = blocks["uSHET cpp_magic.h MIT"]
    ushet_title = "uSHET c09e0acafd86720efe42dc15c63e0cc228244c32 LICENSE (cpp_magic.h)"
    expected_ushet = "\n".join((ROOT / ushet["sourcePath"]).read_text(encoding="utf-8").splitlines()[:22])
    if notice_section(mac, ushet_title) != expected_ushet or notice_section(ios, ushet_title) != expected_ushet:
        fail("uSHET macOS/iOS parity block does not exactly match frozen source")
    openssl_copyright = "Copyright 2014-2020 The OpenSSL Project Authors. All Rights Reserved."
    if mac.count(openssl_copyright) != 1 or ios.count(openssl_copyright) != 1:
        fail("iOS/macOS BoringSSL OpenSSL copyright line must occur exactly once in each notice")
    for block in inventory["sourceHeaderBlocks"]:
        source_paths = block["sourcePath"].split(" and ")
        if len(source_paths) == 2 and "/" not in source_paths[1]:
            source_paths[1] = str(Path(source_paths[0]).with_name(source_paths[1]))
        for source_path, expected_hash in zip(source_paths, block["sha256"].split("; ")):
            require_hash(ROOT / source_path, expected_hash, block["section"])
    headers = {block["section"]: block for block in inventory["sourceHeaderBlocks"]}
    sha_title = "build/SourcePackages/checkouts/swift-nio/Sources/CNIOSHA1/c_nio_sha1.c:10-38 (FreeBSD SHA-1)"
    if notice_section(mac, sha_title) != normalized_lines(ROOT / headers["FreeBSD SHA-1"]["sourcePath"], 9, 38):
        fail("FreeBSD SHA-1 notice is not the frozen source header")
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
    if 'relativePath = Vendor/SwiftTerm;' not in project:
        fail('the product must use the reviewed vendored SwiftTerm')
    verify = subprocess.run([sys.executable, '-B', str(ROOT / 'Tests/Terminal/SwiftTermWrap/verify-vendor.py')],
                            cwd=ROOT, capture_output=True, text=True, timeout=30, check=False)
    if verify.returncode:
        fail('vendored renderer provenance failed: ' + verify.stderr[-1000:])
    mac = (ROOT / inventory['noticeFiles']['macOS']).read_text(encoding='utf-8')
    if notice_section(mac, 'build/SourcePackages/checkouts/SwiftTerm/LICENSE') != normalized_lines(ROOT / 'Vendor/SwiftTerm/LICENSE'):
        fail('retained upstream SwiftTerm license does not match the vendored runtime')
    if '1.20.0-shepherd.saved-wrap-default.1-modified' not in mac:
        fail('modified vendored renderer attribution is missing')
    for product in ("NIOCore", "NIOPosix", "Citadel", "SwiftTerm", "Sparkle", "ShepherdKit", "AgentProxyProtocol"):
        if f"productName = {product};" not in project:
            fail(f"project is missing linked package product {product}")
    manifest = (ROOT / inventory["changeFingerprints"]["localAgentProxy"]).read_text(encoding="utf-8")
    for product in ("AgentProxyProtocol", "AgentProxyCore"):
        if f'.library(name: "{product}"' not in manifest:
            fail(f"local AgentProxy product graph drifted: {product}")
    linked = {entry["identity"] for entry in inventory["linkedOrRetainedUnlinked"] if entry["status"].startswith("linked")}
    if set(STATIC_PRODUCT_EVIDENCE) | {"Sparkle"} != linked:
        fail("gate product evidence mapping no longer matches frozen linked inventory")


def check_source() -> dict:
    inventory = load_inventory()
    mac = (ROOT / inventory["noticeFiles"]["macOS"]).read_text(encoding="utf-8")
    ios = (ROOT / inventory["noticeFiles"]["iOS"]).read_text(encoding="utf-8")
    check_notice_structure(inventory, mac, ios)
    check_notice_sources(inventory, mac, ios)
    check_dependency_graph(inventory)
    check_product_build_inputs()
    return inventory


def check_product_build_inputs() -> None:
    """No CEF/fixture build input, retired target, scheme or payload in the project."""
    sys.path.insert(0, str(ROOT / 'Tests/HcBackend'))
    from product_build_policy import check_product_project, check_sdk_boundary, ProductBuildPolicyFailure
    try:
        check_product_project()
        check_sdk_boundary()
    except ProductBuildPolicyFailure as error:
        fail(str(error))


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
    sys.path.insert(0, str(ROOT / 'Tests/HcBackend'))
    from hc_release_bundle import check_hc_payload, BundlePolicyFailure
    try:
        check_hc_payload(app)
    except BundlePolicyFailure as error:
        fail(str(error))


def architectures(path: Path) -> set[str]:
    """Return Mach-O architectures, failing closed for empty/non-Mach-O inputs."""
    if not path.is_file() or path.stat().st_size == 0:
        fail(f"required linked input is missing or empty: {path}")
    try:
        output = subprocess.run(
            ["lipo", "-archs", str(path)], text=True, capture_output=True, check=False
        )
    except OSError as error:
        fail(f"cannot inspect Mach-O architecture for {path}: {error}")
    if output.returncode != 0:
        fail(f"required linked input is not a valid Mach-O file: {path}")
    result = set(output.stdout.split())
    if not result:
        fail(f"required linked input has no Mach-O architectures: {path}")
    return result


UUID_LINE = re.compile(
    r"UUID: ([0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}) \(([^()]+)\) .+"
)


def uuid_map_from_output(output: str, path: Path, expected_arches: set[str]) -> dict[str, str]:
    """Parse exactly one LC_UUID identity for every expected Mach-O slice."""
    result: dict[str, str] = {}
    for line in output.splitlines():
        match = UUID_LINE.fullmatch(line)
        if match is None:
            fail(f"cannot parse Mach-O UUID evidence for {path}: {line}")
        identity, arch = match.group(1).upper(), match.group(2)
        if arch in result:
            fail(f"duplicate Mach-O UUID evidence for architecture {arch}: {path}")
        result[arch] = identity
    if set(result) != expected_arches:
        fail(f"Mach-O UUID evidence has wrong architectures for {path}: {sorted(result)}")
    if len(set(result.values())) != len(result):
        fail(f"Mach-O UUID evidence has duplicate slice identities: {path}")
    return result


def macho_uuids(path: Path, expected_arches: set[str]) -> dict[str, str]:
    if not path.is_file() or path.stat().st_size == 0:
        fail(f"required Mach-O UUID evidence is missing or empty: {path}")
    try:
        output = subprocess.run(
            ["dwarfdump", "--uuid", str(path)], text=True, capture_output=True, check=False
        )
    except OSError as error:
        fail(f"cannot inspect Mach-O UUID evidence for {path}: {error}")
    if output.returncode != 0:
        fail(f"cannot inspect Mach-O UUID evidence for {path}: {output.stderr.strip()}")
    return uuid_map_from_output(output.stdout, path, expected_arches)


def require_same_uuids(label: str, expected: dict[str, str], actual: dict[str, str]) -> None:
    if actual != expected:
        fail(f"{label} Mach-O UUID identities do not match")


def require_within(path: Path, root: Path, label: str) -> Path:
    try:
        return path.resolve().relative_to(root.resolve())
    except ValueError:
        fail(f"{label} is outside its supplied root: {path}")


def archive_intermediates(derived: Path) -> Path:
    # xcodebuild archive keeps its exact Release target link inputs under this
    # scheme-specific ArchiveIntermediates root, separate from ordinary builds.
    root = derived / "Build/Intermediates.noindex/ArchiveIntermediates/Shepherd"
    if not root.is_dir():
        fail(f"DerivedData has no Shepherd archive link inputs: {root}")
    return root


def link_file_list(archive_root: Path, arch: str) -> Path:
    relative = Path(
        "IntermediateBuildFilesPath/shepherd.build/Release/Shepherd.build/"
        f"Objects-normal/{arch}/hrdrhrdrhrdr.LinkFileList"
    )
    path = archive_root / relative
    if not path.is_file() or path.stat().st_size == 0:
        fail(f"missing Release app target link-file-list for {arch}: {path}")
    return path


def link_inputs(path: Path, derived: Path, arch: str) -> set[Path]:
    result: set[Path] = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        candidate = Path(line)
        if not candidate.is_absolute():
            fail(f"link-file-list has a non-absolute input: {path}")
        require_within(candidate, derived, "link-file-list input")
        if candidate.suffix != ".o":
            fail(f"link-file-list has a non-object input: {candidate}")
        if arch not in architectures(candidate):
            fail(f"link-file-list input lacks target architecture {arch}: {candidate}")
        result.add(candidate.resolve())
    if not result:
        fail(f"link-file-list has no valid object inputs: {path}")
    return result


def framework_binary(framework: Path) -> Path:
    binary = framework / framework.stem
    if not binary.is_file():
        versions = framework / "Versions"
        current = versions / "Current" / framework.stem
        if current.is_file():
            binary = current
    if not binary.is_file():
        fail(f"framework has no executable binary: {framework}")
    return binary


def require_sparkle_load(app_executable: Path) -> None:
    try:
        output = subprocess.run(
            ["otool", "-L", str(app_executable)], text=True, capture_output=True, check=False
        )
    except OSError as error:
        fail(f"cannot inspect app load commands: {error}")
    if output.returncode != 0 or "@rpath/Sparkle.framework/" not in output.stdout:
        fail("app executable does not directly link the embedded Sparkle framework")


def target_dsym(archive_root: Path) -> Path:
    # This is the fixed Xcode archive target output, not a UUID search.  A
    # dSYM exists before signing/export and retains the target LC_UUIDs through
    # normal code-signing and export transformations.
    path = archive_root / "BuildProductsPath/Release/hrdrhrdrhrdr.app.dSYM/Contents/Resources/DWARF/hrdrhrdrhrdr"
    if not path.is_file():
        fail(f"missing exact Release app target dSYM UUID evidence: {path}")
    require_within(path, archive_root, "app target dSYM UUID evidence")
    return path


def bind_build_identities(app_executable: Path, archived_executable: Path, archive_root: Path,
                          target_inputs: dict[str, set[Path]]) -> None:
    """Bind app/archive identities to the exact target whose links were checked.

    LC_UUID is ordinary build-coherence evidence: it rejects a mismatched
    archive/export/DerivedData trio, but is not cryptographic attestation
    against a malicious builder.
    """
    expected_arches = architectures(archived_executable)
    require_same_uuids(
        "archive and supplied app",
        macho_uuids(archived_executable, expected_arches),
        macho_uuids(app_executable, expected_arches),
    )
    # Do not let an output merely found elsewhere in DerivedData bind this
    # target.  These exact link inputs were validated above for every slice.
    for arch in expected_arches:
        if not target_inputs.get(arch):
            fail(f"cannot bind app UUID evidence without exact {arch} link inputs")
    require_same_uuids(
        "archive and exact DerivedData app target output",
        macho_uuids(archived_executable, expected_arches),
        macho_uuids(target_dsym(archive_root), expected_arches),
    )


def matching_archive_and_derived(inputs: Iterable[Path]) -> tuple[Path, Path, Path]:
    roots = [path.resolve() for path in inputs]
    if len(roots) != 2 or len(set(roots)) != 2:
        fail("--products requires exactly one .xcarchive root and one DerivedData root")
    for root in roots:
        if not root.is_dir():
            fail(f"--products input is not an existing directory: {root}")
    archives = [root for root in roots if root.suffix == ".xcarchive" and (root / "Products/Applications/hrdrhrdrhrdr.app").is_dir()]
    derived_roots = [root for root in roots if (root / "Build/Intermediates.noindex").is_dir()]
    if len(archives) != 1 or len(derived_roots) != 1 or archives[0] == derived_roots[0]:
        fail("--products requires the matching .xcarchive and DerivedData roots")
    return archives[0], derived_roots[0], archives[0] / "Products/Applications/hrdrhrdrhrdr.app"


def check_products(inventory: dict, app: Path, inputs: list[Path]) -> None:
    """Exact app-target archive/export/link/dSYM coherence."""
    archive, derived, archived_app = matching_archive_and_derived(inputs)
    check_app(inventory, app)
    check_app(inventory, archived_app)
    main = app / 'Contents/MacOS/hrdrhrdrhrdr'
    archived_main = archived_app / 'Contents/MacOS/hrdrhrdrhrdr'
    if (app / 'Contents/Info.plist').read_bytes() != (archived_app / 'Contents/Info.plist').read_bytes():
        fail('archive and exported Info.plist bytes do not match')
    app_arches = architectures(main)
    if architectures(archived_main) != app_arches:
        fail('archive and exported app architectures do not match')
    sys.path.insert(0, str(ROOT / 'Tests/HcBackend'))
    from hc_release_bundle import inspect_binary, check_no_legacy_backend_symbols, BundlePolicyFailure
    for candidate in (app, archived_app):
        sparkle = candidate / 'Contents/Frameworks/Sparkle.framework'
        if not app_arches <= architectures(framework_binary(sparkle)):
            fail('updater framework lacks a target architecture')
        require_sparkle_load(candidate / 'Contents/MacOS/hrdrhrdrhrdr')
        try:
            inspect_binary(candidate)
        except BundlePolicyFailure as error:
            fail(str(error))
    intermediate_root = archive_intermediates(derived)
    products_root = intermediate_root / 'BuildProductsPath/Release'
    for name in RETIRED_RELEASE_PRODUCTS:
        if (products_root / name).exists():
            fail('Release unexpectedly built a retired product: ' + name)
    target_inputs = {arch: link_inputs(link_file_list(intermediate_root, arch), derived, arch)
                     for arch in sorted(app_arches)}
    evidence = {**STATIC_PRODUCT_EVIDENCE, 'ShepherdKit': ('ShepherdKit.o',)}
    for identity, filenames in evidence.items():
        for filename in filenames:
            expected = (products_root / filename).resolve()
            for arch in app_arches:
                if expected not in target_inputs[arch]:
                    fail(f'linked product evidence unavailable for {identity}: {filename}')
    for arch in app_arches:
        retired = sorted(path.name for path in target_inputs[arch] if path.name in RETIRED_RELEASE_PRODUCTS)
        if retired:
            fail('app links a retired product: ' + ', '.join(retired))
    try:
        check_no_legacy_backend_symbols(products_root / 'ShepherdKit.o')
    except BundlePolicyFailure as error:
        fail(str(error))
    for arch in app_arches:
        filelist = intermediate_root / ('IntermediateBuildFilesPath/ShepherdKit.build/Release/'
                                       f'ShepherdKit-t.build/Objects-normal/{arch}/ShepherdKit.SwiftFileList')
        if not filelist.is_file(): fail('SDK compiler source evidence is missing')
        names = {Path(line.strip().strip('"')).name for line in filelist.read_text().splitlines() if line.strip()}
        if not {'CoreWire.swift', 'HcTerminalBoard.swift', 'MachineStore+Hc.swift', 'ConversationClient.swift', 'ShellQuoting.swift'} <= names:
            fail('SDK core/shared SSH/archive source evidence is incomplete')
    bind_build_identities(main, archived_main, intermediate_root, target_inputs)


def stamp_version(version: str) -> None:
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", version):
        fail(f"invalid notice version: {version}")
    path = ROOT / "Shepherd/ThirdPartyNotices.txt"
    text = path.read_text(encoding="utf-8")
    updated, count = re.subn(r"\AThird-party notices for hrdrhrdrhrdr [0-9]+(?:\.[0-9]+){1,2}", f"Third-party notices for hrdrhrdrhrdr {version}", text)
    if count != 1:
        fail("cannot stamp an unrecognized macOS notice header")
    path.write_text(updated, encoding="utf-8")


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
    rejected(
        "missing iOS BoringSSL OpenSSL copyright line",
        lambda: check_notice_sources(
            inventory,
            mac,
            ios.replace("Copyright 2014-2020 The OpenSSL Project Authors. All Rights Reserved.\n", "", 1),
        ),
    )
    rejected("source attribution hash", lambda: require_hash(ROOT / inventory["verbatimBlocks"][0]["sourcePath"], "0" * 64, "fixture"))
    rejected("package pin drift", lambda: check_dependency_graph({**inventory, "changeFingerprints": {**inventory["changeFingerprints"], "packageResolved": "Tests/Notices/fixtures/missing.json"}}))

    uuid_path = Path("fixture-macho")
    valid_uuids = {
        "arm64": "11111111-1111-1111-1111-111111111111",
        "x86_64": "22222222-2222-2222-2222-222222222222",
    }
    rejected(
        "missing Mach-O UUID slice",
        lambda: uuid_map_from_output(
            "UUID: 11111111-1111-1111-1111-111111111111 (arm64) fixture-macho\\n", uuid_path, set(valid_uuids)
        ),
    )
    rejected(
        "duplicate Mach-O UUID architecture",
        lambda: uuid_map_from_output(
            "UUID: 11111111-1111-1111-1111-111111111111 (arm64) fixture-macho\\n"
            "UUID: 22222222-2222-2222-2222-222222222222 (arm64) fixture-macho\\n", uuid_path, set(valid_uuids)
        ),
    )
    rejected(
        "duplicate Mach-O UUID identity",
        lambda: uuid_map_from_output(
            "UUID: 11111111-1111-1111-1111-111111111111 (arm64) fixture-macho\\n"
            "UUID: 11111111-1111-1111-1111-111111111111 (x86_64) fixture-macho\\n", uuid_path, set(valid_uuids)
        ),
    )
    rejected(
        "wrong-target Mach-O UUID output",
        lambda: require_same_uuids("archive and exact DerivedData app target output", valid_uuids, {**valid_uuids, "arm64": "33333333-3333-3333-3333-333333333333"}),
    )
    rejected(
        "mismatched archive/export Mach-O UUIDs",
        lambda: require_same_uuids("archive and supplied app", valid_uuids, {**valid_uuids, "x86_64": "44444444-4444-4444-4444-444444444444"}),
    )

    with tempfile.TemporaryDirectory(prefix="shphrd-87-notices-") as temporary:
        fixture = Path(temporary)
        app = fixture / "fixture.app"
        resources = app / "Contents/Resources"
        resources.mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.6.0"}))
        shutil.copy2(ROOT / inventory["noticeFiles"]["macOS"], resources / "ThirdPartyNotices.txt")
        check_app(inventory, app)
        (resources / 'AgentRuntime').mkdir()
        rejected('excluded agent runtime', lambda: check_app(inventory, app))
        (resources / 'AgentRuntime').rmdir()

        # Product fixtures deliberately use empty objects and misleading names.
        # The gate has no synthetic success path: only real archive/DerivedData
        # target link inputs can pass, so these must all fail closed.
        products = fixture / "products"
        products.mkdir()
        for filenames in STATIC_PRODUCT_EVIDENCE.values():
            for filename in filenames:
                (products / filename).touch()
        misleading = fixture / "BigInt-NIOCore-AgentProxyForwarder-Release.xcarchive"
        misleading.mkdir()
        rejected("arbitrary empty named products", lambda: check_products(inventory, app, [products, misleading]))
        rejected("misleading product path tokens", lambda: check_products(inventory, app, [misleading, products]))
        rejected("wrong product roots", lambda: check_products(inventory, app, [products, fixture]))
        (products / "AgentProxyCore.o").unlink()
        rejected("missing AgentProxyCore", lambda: check_products(inventory, app, [products, misleading]))
        rejected("incomplete product evidence", lambda: check_products(inventory, app, [products, fixture]))

        (resources / "ThirdPartyNotices.txt").write_text("stale\n", encoding="utf-8")
        rejected("app notice/version content mismatch", lambda: check_app(inventory, app))
        shutil.copy2(ROOT / inventory["noticeFiles"]["macOS"], resources / "ThirdPartyNotices.txt")
        (resources / "ChromiumCredits.html").write_text("stale\n", encoding="utf-8")
        rejected("excluded Chromium credits", lambda: check_app(inventory, app))
    print("self-test: all negative guards rejected")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="exported macOS .app to validate")
    parser.add_argument("--products", type=Path, nargs="+", metavar="PATH", help="archive and DerivedData/product-evidence paths")
    parser.add_argument("--self-test", action="store_true", help="exercise synthetic failing guards")
    parser.add_argument("--stamp-version", metavar="VERSION", help="write the release version into the macOS notice header")
    parser.add_argument('--profile', choices=['hc'], default='hc',
                        help='the hc Release product (the only profile; kept for the release script)')
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
            if not args.app:
                fail("--products requires --app so evidence is tied to the exported app")
            check_products(inventory, args.app, args.products)
    except NoticeFailure as error:
        print(f"error: {error}", file=os.sys.stderr)
        return 1
    print("Third-party notice gate passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
