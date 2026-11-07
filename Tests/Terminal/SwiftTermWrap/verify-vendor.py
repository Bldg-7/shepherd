#!/usr/bin/env python3
"""Read-only provenance/binding gate. No source checkout mutations or scans."""
from pathlib import Path
import hashlib,json
ROOT=Path(__file__).resolve().parents[3]
v=ROOT/'Vendor/SwiftTerm'
m=json.loads((v/'source-hashes.json').read_text())
assert m['baseCommit']=='5d14406844143538cd8f8851d2d8a67c1fe443e5'
h=lambda data:hashlib.sha256(data).hexdigest()
changed=[]
for name,entry in m['files'].items():
    assert h((v/name).read_bytes())==entry['vendoredSHA256'],name
    if entry['upstreamSHA256']!=entry['vendoredSHA256']:changed.append(name)
assert changed==['Sources/SwiftTerm/Buffer.swift'],changed
buffer=(v/changed[0]).read_bytes()
assert buffer.count(b'var savedWraparound: Bool = true')==1
assert buffer.count(b'        savedWraparound = true')==1
original=buffer.replace(b'var savedWraparound: Bool = true',b'var savedWraparound: Bool = false').replace(b'        savedWraparound = true',b'        savedWraparound = false')
assert h(original)==m['files'][changed[0]]['upstreamSHA256'],'more than the two declared renderer changes'
actual={str(p.relative_to(v)) for base in ['Sources/SwiftTerm','Tests/SwiftTermTests'] for p in (v/base).rglob('*') if p.is_file()}
expected={name for name in m['files'] if name.startswith(('Sources/','Tests/'))}|{'Sources/SwiftTerm/SwiftTermBuildInfo.swift','Tests/SwiftTermTests/SavedCursorWrapTests.swift'}
assert actual==expected,(actual-expected,expected-actual)
identity=(v/'Sources/SwiftTerm/SwiftTermBuildInfo.swift').read_text()
assert m['baseCommit'] in identity and '1.20.0-shepherd.saved-wrap-default.1-modified' in identity
manifest=(v/'Package.swift').read_text()
assert 'swiftLanguageModes: [.v5]' in manifest and '.process("Apple/Metal/Shaders.metal")' in manifest
assert '.package(' not in manifest and '.plugin(' not in manifest
project=(ROOT/'shepherd.xcodeproj/project.pbxproj').read_text()
assert 'repositoryURL = "https://github.com/migueldeicaza/SwiftTerm"' not in project
assert 'relativePath = Vendor/SwiftTerm;' in project
assert 'package = 9B506EB5306F4D21005B40C9 /* XCLocalSwiftPackageReference "Vendor/SwiftTerm" */;' in project
print('PASS vendored SwiftTerm:151 upstream files sealed; exact two-default delta; explicit modified identity; local product binding')
