#if os(macOS)
import Foundation

/// Produced from owned SHBPage/CefBrowser/CefFrame lifecycle, never agent JSON.
nonisolated struct CredentialNativeIdentity: Equatable, Sendable {
    let browserID: String
    let frameID: String
    let documentGeneration: UInt64
}

/// Uses native CDP only for the resolved pane's existing public page. No CSS
/// lookup, agent evaluation, private controller target or DOM mutation API.
@MainActor final class NativeCredentialElementInspector: CredentialElementInspecting {
    private final class PageLease {
        let transport: NativeCDPTransport
        let nativeOwner: NativeCDPTransport.Owner
        let session: String
        let owner: CredentialOwner
        let pageID: String
        var revision: UInt64 = 1
        var live = true
        init(_ transport: NativeCDPTransport, _ nativeOwner: NativeCDPTransport.Owner,
             _ session: String, _ owner: CredentialOwner, _ pageID: String) {
            self.transport = transport; self.nativeOwner = nativeOwner
            self.session = session; self.owner = owner; self.pageID = pageID
        }
    }
    private var pages: [String: PageLease] = [:]
    private let nativeIdentity: (BrowserPage, String) -> CredentialNativeIdentity?
    private let activeOwner: (CredentialOwner) -> Bool
    private let detached: (CredentialOwner, String) -> Void
    init(activeOwner: @escaping (CredentialOwner) -> Bool,
         nativeIdentity: @escaping (BrowserPage, String) -> CredentialNativeIdentity?,
         detached: @escaping (CredentialOwner, String) -> Void) {
        self.nativeIdentity = nativeIdentity
        self.activeOwner = activeOwner; self.detached = detached
    }

    private func owningPage(_ input: CredentialBindInput, _ owner: CredentialOwner) throws -> BrowserTab {
        guard ShepherdBrowserFeature.shared.isEnabled, activeOwner(owner),
              owner.herdrMachineID.isEmpty, let machine = UUID(uuidString: owner.machineID) else { throw CredentialBrokerError.denied }
        let key = BrowserKey(machineID: machine, herdrMachineID: nil, session: owner.session, paneID: owner.paneID)
        guard MachineBrowserService.shared.isLocal(key), let browser = BrowserStore.shared.browser(for: key),
              browser.terminalID == owner.terminalID, browser.profile.folderName == owner.profileID,
              let tab = browser.tabs.first(where: { $0.cdpTargetID == input.pageID }),
              tab.page?.isClosed == false else { throw CredentialBrokerError.invalidElement }
        return tab
    }
    func revoke(owner: CredentialOwner) {
        for (id, lease) in pages where lease.owner == owner {
            lease.live = false; pages[id] = nil
            lease.transport.retire(lease.nativeOwner) {}
        }
    }
    private func check(_ lease: PageLease, input: CredentialBindInput, revision: UInt64) throws {
        _ = try owningPage(input, lease.owner)
        guard lease.live, lease.revision == revision, !lease.transport.failed,
              UInt64(BrowserEngine.generation) == UInt64(lease.transport.generation) else { throw CredentialBrokerError.invalidElement }
    }
    private func acquire(_ input: CredentialBindInput, _ owner: CredentialOwner) async throws -> PageLease {
        _ = try owningPage(input, owner)
        if let lease = pages[input.pageID] {
            guard lease.owner == owner, lease.live else { throw CredentialBrokerError.invalidElement }
            return lease
        }
        guard pages.count < 64 else { throw CredentialBrokerError.capacity }
        let (transport, nativeOwner) = try await NativeCDPController.shared.acquire()
        do {
            _ = try owningPage(input, owner)
            let result = try await transport.call(nativeOwner, "Target.attachToTarget", params: ["targetId":input.pageID,"flatten":true])
            guard let session = result["sessionId"] as? String, pages[input.pageID] == nil else { throw CredentialBrokerError.invalidElement }
            let lease = PageLease(transport,nativeOwner,session,owner,input.pageID)
            // Any document/context loss invalidates rather than guessing a new
            // document identity. Future binds require lifecycle retirement.
            nativeOwner.events = { [weak self, weak lease] message in
                guard let self, let lease else { return }
                let method = message["method"] as? String ?? ""
                if ["Page.frameNavigated","Page.frameDetached","Runtime.executionContextsCleared","Runtime.executionContextDestroyed","DOM.documentUpdated","Target.detachedFromTarget"].contains(method) {
                    lease.live = false; lease.revision += 1; self.detached(owner,input.pageID)
                }
            }
            nativeOwner.failed = { [weak self, weak lease] in
                lease?.live = false; self?.detached(owner,input.pageID)
            }
            pages[input.pageID] = lease
            for method in ["Page.enable","Runtime.enable","DOM.enable"] {
                _ = try await transport.call(nativeOwner,method,session:session)
            }
            return lease
        } catch {
            if pages[input.pageID]?.nativeOwner === nativeOwner { pages[input.pageID]?.live = false; pages[input.pageID] = nil }
            transport.retire(nativeOwner) {}; throw CredentialBrokerError.unavailable
        }
    }
    @MainActor func snapshot(_ input: CredentialBindInput, owner: CredentialOwner) async throws -> TrustedElementSnapshot {
        guard let page = try owningPage(input,owner).page,
              let identity = nativeIdentity(page,input.frameID), identity.frameID == input.frameID,
              !identity.browserID.isEmpty, identity.documentGeneration > 0 else { throw CredentialBrokerError.unavailable }
        let lease = try await acquire(input, owner)
        let revision = lease.revision
        @MainActor func verify() throws {
            try check(lease,input:input,revision:revision)
            guard try owningPage(input,owner).page === page,
                  nativeIdentity(page,input.frameID) == identity else { throw CredentialBrokerError.invalidElement }
        }
        try verify()
        let world = try await lease.transport.call(lease.nativeOwner,"Page.createIsolatedWorld",
            params:["frameId":input.frameID,"worldName":"shepherd-credential-inspection","grantUniveralAccess":false],session:lease.session)
        try verify()
        guard let context = world["executionContextId"] as? Int, context > 0 else { throw CredentialBrokerError.invalidElement }
        let described = try await lease.transport.call(lease.nativeOwner,"DOM.describeNode",
            params:["backendNodeId":input.backendNodeID,"depth":0],session:lease.session)
        try verify()
        guard let description = described["node"] as? [String:Any],
              description["backendNodeId"] as? Int == input.backendNodeID,
              description["nodeType"] as? Int == 1,
              description["localName"] as? String == "input" else { throw CredentialBrokerError.invalidElement }
        let node = try await lease.transport.call(lease.nativeOwner,"DOM.resolveNode",
            params:["backendNodeId":input.backendNodeID,"executionContextId":context],session:lease.session)
        try verify()
        guard let object = node["object"] as? [String:Any], let id = object["objectId"] as? String else { throw CredentialBrokerError.invalidElement }
        defer { Task { _ = try? await lease.transport.call(lease.nativeOwner,"Runtime.releaseObject",params:["objectId":id],session:lease.session) } }
        let inspected = try await lease.transport.call(lease.nativeOwner,"Runtime.callFunctionOn",params:[
            "objectId":id,"returnByValue":true,"functionDeclaration":Self.inspect],session:lease.session)
        try verify()
        guard inspected["exceptionDetails"] == nil, let remote = inspected["result"] as? [String:Any],
              let value = remote["value"] as? [String:Any], value["valid"] as? Bool == true,
              let type = value["type"] as? String, let name = value["name"] as? String,
              let action = value["action"] as? String, let method = value["method"] as? String,
              let enctype = value["enctype"] as? String, let origin = value["origin"] as? String,
              let text = value["value"] as? String else { throw CredentialBrokerError.invalidElement }
        let destination = try CredentialDestination(url:action,method:method.uppercased(),mediaType:enctype,field:name)
        return TrustedElementSnapshot(owner:owner,engineGeneration:UInt64(lease.transport.generation),browserID:identity.browserID,
            pageID:input.pageID,frameID:identity.frameID,documentGeneration:identity.documentGeneration,
            executionContextGeneration:UInt64(context),backendNodeID:input.backendNodeID,origin:origin,
            connected:true,inputType:type,name:name,formDestination:destination,ordinaryForm:true,value:text)
    }
    @MainActor func revalidate(_ binding: CredentialBinding) async throws -> TrustedElementSnapshot {
        try await snapshot(binding.input,owner:binding.snapshot.owner)
    }
    private static let inspect = """
    function() {
      if (!(this instanceof HTMLInputElement) || this.ownerDocument !== document || !this.isConnected || !this.form || !this.form.isConnected) return {valid:false};
      const f=this.form;
      if (!['text','password'].includes(this.type) || this.disabled || !this.name || f.getAttribute('onsubmit') || Array.from(f.elements).filter(e=>e.name===this.name && !e.disabled).length!==1) return {valid:false};
      const submitters=Array.from(f.elements).filter(e=>e instanceof HTMLButtonElement || (e instanceof HTMLInputElement && ['submit','image'].includes(e.type)));
      if (submitters.some(e=>['formaction','formmethod','formenctype'].some(a=>e.hasAttribute(a)))) return {valid:false};
      return {valid:true,type:this.type,name:this.name,action:f.action,method:f.method,enctype:f.enctype,origin:location.origin,value:this.value};
    }
    """
}
#endif
