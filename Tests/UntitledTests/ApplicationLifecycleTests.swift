import AppKit
import Testing
@testable import Untitled

@Suite(.serialized) @MainActor
struct ApplicationLifecycleTests {
    @Test(arguments: [false, true])
    func dockReopenExplicitlyOpensMainPanelEvenWhenOtherWindowsAreVisible(hasVisibleWindows: Bool) {
        let delegate = CaptureAppDelegate()
        var opens = 0
        delegate.showMainWindow = { opens += 1 }

        let useDefaultHandling = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: hasVisibleWindows)

        #expect(opens == 1)
        #expect(!useDefaultHandling)
    }

    @Test(arguments: [false, true])
    func reopenBeforeMainSceneIsReadyPreservesDefaultHandling(hasVisibleWindows: Bool) {
        let delegate = CaptureAppDelegate()
        #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: hasVisibleWindows))
    }

    @Test func repeatedDockClicksKeepUsingTheRegisteredMainPanelAction() {
        let delegate = CaptureAppDelegate()
        var opens = 0
        delegate.showMainWindow = { opens += 1 }

        for hasVisibleWindows in [true, false, true, false] {
            #expect(!delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: hasVisibleWindows))
        }

        #expect(opens == 4)
    }
}
