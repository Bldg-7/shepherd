// ShepherdKit, re-exported for the whole app, as the macOS app does it
// (Shepherd/ShepherdKitImport.swift): the pairing sources under Pairing/
// that don't need iOS say no `import ShepherdKit` of their own, so that the
// test runner under Tests/Pairing compiles them on a Mac together with the
// package's sources, with no ShepherdKit module to import. This file is in
// none of its lists.
@_exported import ShepherdKit
