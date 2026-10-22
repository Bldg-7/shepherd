// The app's one import of the agent proxy's protocol (AgentProxy/, SHPHRD-105),
// re-exported as ShepherdKitImport.swift does ShepherdKit, so that the test
// runners under Tests/, which compile the app's sources together with the
// package's, with no AgentProxyProtocol module to import, go on compiling
// them: this file is in none of their lists.
@_exported import AgentProxyProtocol
