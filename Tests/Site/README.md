# Site checks

Run the privacy-policy checks from any directory:

```sh
python3 Tests/Site/run-privacy-tests.py
```

Python's standard library only; no app, browser, network or build is started.
The checks parse the English and Korean articles and compare their element
structure, language anchors, headings, list counts and effective dates. They
require the QR-pairing disclosures (request fields, encrypted public key,
camera use, listener lifetime, saved history and device removal), and reject
the old SSH-only claim. Mutation checks remove or alter a language, date,
disclosure, history limit and closing tag to exercise the validator.

`--html /path/to/index.html` checks a saved page instead. These are structural
and wording regression checks, not proof of runtime data handling or a legal
review. When pairing behavior or the policy changes, compare the policy with
`PairingProtocol.swift`, `PairedDeviceStore.swift`, `PairingCoordinator.swift`
and the mobile pairing scanner/client, then update the expectations together.

For a published update, also confirm the Pages workflow succeeded and check
that the public `/privacy/` page has the new effective date in both languages.
