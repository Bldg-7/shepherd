#if os(macOS)
import Foundation

nonisolated extension AgentPaneIdentity {
    init(key: BrowserKey, terminalID: String) {
        self.init(machineID: key.machineID.uuidString, herdrMachineID: key.herdrMachineID,
                  session: key.session, paneID: key.paneID, terminalID: terminalID)
    }
}

nonisolated extension AgentBrowserEndpoint {
    init(_ endpoint: BrowserEndpoint) {
        self.init(origin: "thisMac", url: endpoint.url.absoluteString, tokenFile: endpoint.tokenFile.path)
    }
}

nonisolated extension AgentRuntime {
    init(root: String, resourceDirectory: String, nodeExecutable: String = "node", client: HerdrClient) {
        self.init(root: root, resourceDirectory: resourceDirectory, nodeExecutable: nodeExecutable,
                  scriptRunner: { try await client.runScript($0) })
    }
}
#endif
