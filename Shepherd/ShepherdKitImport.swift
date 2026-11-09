// The app's one import of ShepherdKit, re-exported, so that every file of the
// app sees the package's types as it saw them when they were the app's own —
// and so that the test runners under Tests/, which compile the app's sources
// file by file together with the package's, with no ShepherdKit module to
// import, go on compiling them: this file is in none of their lists.
@_exported import ShepherdKit
