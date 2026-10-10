#if os(macOS)
import Foundation

@MainActor extension ShepherdBrowserFeature {
    func setEnabled(_ enabled: Bool, presentationOwner: UUID? = nil) async {
        await setEnabled(enabled, presentationOwner: presentationOwner, canDisable: {
            !AgentLaunchService.shared.browserDisableBlocked && !CDPProxy.shared.hasBrowserWork
        }, transition: {
            if enabled {
                BrowserEngine.prepare()
                AgentLaunchService.shared.start()
                #if DEBUG
                if let configuration = OwnedOperatorFixture.configuration {
                    MachineBrowserService.shared.update(machines: [configuration.machine], localSocketPaths: [configuration.machine.id: configuration.socket])
                } else {
                    MachineBrowserService.shared.resume()
                }
                let port = OwnedOperatorFixture.configuration == nil ? UserDefaults.standard.object(forKey: "browserAgentPort") as? Int ?? 9333 : 0
                #else
                MachineBrowserService.shared.resume()
                let port = UserDefaults.standard.object(forKey: "browserAgentPort") as? Int ?? 9333
                #endif
                await CDPProxy.shared.start(port: port)
            } else {
                MachineBrowserService.shared.stop()
                await AgentLaunchService.shared.stop()
                await CDPProxy.shared.stop()
                BrowserStore.shared.suspendForFeatureDisable()
            }
        })
    }
}
#endif
