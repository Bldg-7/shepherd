import AppKit
import Foundation

/// Own never-shown windows and synthetic control notifications. Not a physical
/// input/IME qualification; the actual-root audit exercises real editing too.
@main @MainActor private struct HcTextInputOwnershipTests {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var n = 0
        func check(_ value: Bool, _ label: String) { precondition(value,label); n += 1 }
        let presentation = HcWorkspacePresentation()
        let root = NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:200),styleMask:[.titled],backing:.buffered,defer:false)
        let other = NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:200),styleMask:[.titled],backing:.buffered,defer:false)
        root.isReleasedWhenClosed = false; other.isReleasedWhenClosed = false
        let anchor = HcTextInputOwnership.Anchor(presentation:presentation)
        root.contentView!.addSubview(anchor)
        let field = NSTextField(string:"owned"), foreign = NSTextField(string:"other owned window")
        root.contentView!.addSubview(field); other.contentView!.addSubview(foreign)
        let generation = presentation.inputGeneration
        NotificationCenter.default.post(name:NSControl.textDidBeginEditingNotification,object:foreign)
        check(!presentation.textFieldOwnsKeyboard && presentation.inputGeneration == generation,"another window cannot claim this keyboard lease")
        NotificationCenter.default.post(name:NSControl.textDidBeginEditingNotification,object:field)
        check(presentation.textFieldOwnsKeyboard && presentation.inputGeneration != generation,"same-window control begins ownership")
        let current = presentation.inputGeneration
        NotificationCenter.default.post(name:NSControl.textDidEndEditingNotification,object:foreign)
        check(presentation.textFieldOwnsKeyboard && presentation.inputGeneration == current,"another control cannot end the lease")
        NotificationCenter.default.post(name:NSControl.textDidEndEditingNotification,object:field)
        check(!presentation.textFieldOwnsKeyboard && presentation.inputGeneration == current,"end releases ownership without reviving older requests")
        NotificationCenter.default.post(name:NSControl.textDidBeginEditingNotification,object:field)
        check(presentation.textFieldOwnsKeyboard,"ownership may be reacquired")
        anchor.removeFromSuperview()
        check(!presentation.textFieldOwnsKeyboard,"detachment retires only this anchor's lease")
        let stopped = presentation.inputGeneration
        NotificationCenter.default.post(name:NSControl.textDidBeginEditingNotification,object:field)
        check(!presentation.textFieldOwnsKeyboard && presentation.inputGeneration == stopped,"detached observer cannot claim ownership")
        root.close(); other.close()
        print("PASS native input-ownership component: \(n) checks; no shown windows or physical GUI approval")
    }
}
