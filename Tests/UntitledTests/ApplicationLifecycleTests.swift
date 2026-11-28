import AppKit
import Testing
import UntitledPluginSDK
@testable import UntitledHost
@testable import UntitledPluginCapture
@testable import UntitledPluginSharing
@testable import UntitledPluginSpeech
@testable import UntitledComposition

@Suite(.serialized) @MainActor
struct ApplicationLifecycleTests {
    @Test(arguments: [false, true])
    func dockReopenExplicitlyOpensMainPanelEvenWhenOtherWindowsAreVisible(hasVisibleWindows: Bool) {
        let delegate = UntitledAppDelegate()
        var opens = 0
        delegate.showMainWindow = { opens += 1 }

        let useDefaultHandling = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: hasVisibleWindows)

        #expect(opens == 1)
        #expect(!useDefaultHandling)
    }

    @Test(arguments: [false, true])
    func reopenBeforeMainSceneIsReadyPreservesDefaultHandling(hasVisibleWindows: Bool) {
        let delegate = UntitledAppDelegate()
        #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: hasVisibleWindows))
    }

    @Test func repeatedDockClicksKeepUsingTheRegisteredMainPanelAction() {
        let delegate = UntitledAppDelegate()
        var opens = 0
        delegate.showMainWindow = { opens += 1 }

        for hasVisibleWindows in [true, false, true, false] {
            #expect(!delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: hasVisibleWindows))
        }

        #expect(opens == 4)
    }
}
