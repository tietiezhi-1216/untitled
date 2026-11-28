import AppKit
import UntitledPluginSDK
import SwiftUI

package enum PanelLayout {
    package static let windowControlsHeight: CGFloat = 60
    package static let windowControlsLeading: CGFloat = 18
    package static let windowControlsTop: CGFloat = 18
    package static let coordinateSpace = "panel.content"
    package static let sidebarWidth: CGFloat = 224
    package static let contentInset: CGFloat = 28
    package static let contentVerticalInset: CGFloat = 16
    package static let rowInset: CGFloat = 18
    package static let itemSpacing: CGFloat = 16
    package static let iconSize: CGFloat = 40
    package static let actionWidth: CGFloat = 76
    package static let headerActionSize: CGFloat = 32
    package static let headerActionSpacing: CGFloat = 8
}

enum PanelPalette {
    static func window(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.085, green: 0.085, blue: 0.095) : Color(red: 0.965, green: 0.965, blue: 0.975)
    }

    static func content(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.105, green: 0.105, blue: 0.115) : Color(red: 0.985, green: 0.985, blue: 0.99)
    }

    static func store(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.125, green: 0.112, blue: 0.15) : Color(red: 0.985, green: 0.985, blue: 0.995)
    }

    static func sidebar(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.095, green: 0.095, blue: 0.105) : Color(red: 0.95, green: 0.95, blue: 0.96)
    }
}

/// Shared, always-visible scroll indicator for the two main galleries.
package struct PanelGalleryScroll<Content: View>: View {
    private static var indicatorInset: CGFloat { 8 }
    let leadingInset: CGFloat
    let trailingInset: CGFloat
    let content: Content

    package init(leadingInset: CGFloat, trailingInset: CGFloat, @ViewBuilder content: () -> Content) {
        self.leadingInset = leadingInset
        self.trailingInset = trailingInset
        self.content = content()
    }

    package var body: some View {
        let edge = Self.indicatorInset
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        ScrollView {
            content
                .padding(.leading, leadingInset)
                // AppKit already reserves the indicator's width. Leave room for
                // its inward shift plus a gap without narrowing the grid twice.
                .padding(.trailing, max(trailingInset - scrollerWidth, edge + 8))
                .background(alignment: .topTrailing) {
                    PanelGalleryScrollIndicator()
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        }
        .contentMargins(.all, EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: edge), for: .scrollIndicators)
    }
}

struct PanelGalleryScrollIndicator: NSViewRepresentable {
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ anchor: Anchor, context: Context) { anchor.installScroller() }

    final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let notifications = NotificationCenter.default
            let name = NSScroller.preferredScrollerStyleDidChangeNotification
            notifications.removeObserver(self, name: name, object: nil)
            guard window != nil else { return }
            notifications.addObserver(self, selector: #selector(scrollerPreferenceChanged), name: name, object: nil)
            installScroller()
        }

        @objc nonisolated private func scrollerPreferenceChanged() {
            DispatchQueue.main.async { [weak self] in self?.installScroller() }
        }

        func installScroller() {
            guard window != nil, let scroll = enclosingScrollView else { return }
            // Non-overlay scrollers do not fade. Scope this choice to the
            // gallery, without writing the system scroll-bar preference.
            if scroll.scrollerStyle != .legacy { scroll.scrollerStyle = .legacy }
            if scroll.autohidesScrollers { scroll.autohidesScrollers = false }
            if let current = scroll.verticalScroller, !(current is PanelGalleryScroller) {
                let scroller = PanelGalleryScroller(frame: current.frame)
                scroller.controlSize = .regular
                scroll.verticalScroller = scroller
            }
        }
    }
}

final class PanelGalleryScroller: NSScroller {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // AppKit disables the scroller when there is no content to scroll.
        guard isEnabled, knobProportion > 0, knobProportion < 1 else { return }
        let slot = rect(for: .knobSlot)
        let knob = rect(for: .knob)
        // The App Store reference has one 11-point column for both pills.
        // Limit drawing only; AppKit still owns the native hit areas.
        let width = min(11, slot.width, knob.width)
        guard width > 0 else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            fillCapsule(slot, width: width, opacity: increasedContrast ? 0.16 : 0.047)
            fillCapsule(knob, width: width, opacity: increasedContrast ? 0.8 : 0.55)
        }
    }

    private func fillCapsule(_ rect: NSRect, width: CGFloat, opacity: CGFloat) {
        guard !rect.isEmpty else { return }
        let shape = rect.insetBy(dx: (rect.width - width) / 2, dy: 0)
        let radius = min(shape.width, shape.height) / 2
        NSColor.labelColor.withAlphaComponent(opacity).setFill()
        NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius).fill()
    }
}

struct PanelDivider: View {
    package var body: some View {
        Divider()
            .padding(.horizontal, PanelLayout.contentInset)
    }
}

struct PanelIcon: View {
    let symbol: String
    var size: CGFloat = PanelLayout.iconSize

    package var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.475, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: size / 4))
            .accessibilityHidden(true)
    }
}

/// Shared chrome for native Buttons and Menus in the plugin header.
struct PluginHeaderIconStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        Face(label: configuration.label, pressed: configuration.isPressed, prominent: prominent)
    }

    private struct Face<Label: View>: View {
        let label: Label
        let pressed: Bool
        let prominent: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.colorSchemeContrast) private var contrast
        @ViewState private var hovered = false

        private var fill: Color {
            let tint: Color = prominent && enabled ? .accentColor : .primary
            if !enabled { return tint.opacity(0.045) }
            if pressed { return tint.opacity(0.24) }
            if hovered { return tint.opacity(0.16) }
            return tint.opacity(prominent ? 0.16 : 0.085)
        }

        var body: some View {
            label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(enabled ? 1 : 0.42))
                .frame(width: PanelLayout.headerActionSize, height: PanelLayout.headerActionSize)
                .background(fill, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.25 : 0.09))
                        .allowsHitTesting(false)
                }
                .contentShape(Circle())
                .onHover { hovered = $0 }
        }
    }
}

/// A passive AppKit tracking rect also works over native menus and disabled
/// controls, where SwiftUI's .help isn't consistently displayed.
struct PluginHeaderHoverTracking: NSViewRepresentable {
    let title: String
    let show: (Bool) -> Void

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ anchor: Anchor, context: Context) {
        anchor.title = title
        anchor.show = show
    }
    static func dismantleNSView(_ anchor: Anchor, coordinator: ()) {
        anchor.show = nil
        anchor.dismiss()
    }

    final class Anchor: NSView {
        private static weak var active: Anchor?
        var title = ""
        var show: ((Bool) -> Void)?
        var waitForDwell: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        private var tracking: NSTrackingArea?
        private var delay: Task<Void, Never>?
        private var monitor: Any?
        private var isShowing = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); dismiss() }
        override func viewDidHide() { super.viewDidHide(); dismiss() }

        override func mouseEntered(with event: NSEvent) {
            guard let window, !title.isEmpty, Self.active !== self else { return }
            Self.active?.dismiss()
            Self.active = self
            NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
                name: NSWindow.didResignKeyNotification, object: window)
            // Observe only while hovered, and never consume the event.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [
                .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel,
            ]) { [weak self] event in
                self?.dismiss()
                return event
            }

            delay = Task { @MainActor [weak self, wait = waitForDwell] in
                do { try await wait(.milliseconds(300)); try Task.checkCancellation() } catch { return }
                guard let self, Self.active === self else { return }
                delay = nil
                guard self.window?.isVisible == true, !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else {
                    dismiss()
                    return
                }
                isShowing = true
                show?(true)
            }
        }

        override func mouseExited(with event: NSEvent) { dismiss() }

        @objc private func windowResignedKey(_: Notification) { dismiss() }

        func dismiss() {
            delay?.cancel()
            delay = nil
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
            if Self.active === self { Self.active = nil }
            if isShowing {
                isShowing = false
                show?(false)
            }
        }
    }
}

private struct PluginHeaderHint: ViewModifier {
    let title: String
    @ViewState private var visible = false
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background { PluginHeaderHoverTracking(title: title, show: { visible = $0 }).accessibilityHidden(true) }
            .overlay {
                if visible {
                    PluginHeaderHintPlacement {
                        let shape = RoundedRectangle(cornerRadius: 7)
                        Text(verbatim: title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .foregroundStyle(.primary)
                            .background(Color(nsColor: .controlBackgroundColor), in: shape)
                            .overlay { shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.55 : 0.17)) }
                            .shadow(color: .black.opacity(0.24), radius: 5, y: 2)
                            .panelRegion("plugin.header.hoverHint")
                    }
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                }
            }
            .zIndex(visible ? 1 : 0)
    }
}

/// Size to the underlying icon; place the label out of flow in the header's padding.
private struct PluginHeaderHintPlacement: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: PanelLayout.headerActionSize,
                                                            height: PanelLayout.headerActionSize))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let label = subviews.first else { return }
        let size = label.sizeThatFits(ProposedViewSize(width: 240, height: nil))
        let rightEdge = bounds.maxX + PanelLayout.contentInset - 8
        let x = min(bounds.midX - size.width / 2, rightEdge - size.width)
        label.place(at: CGPoint(x: x, y: bounds.maxY + 6), anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

extension View {
    func pluginHeaderHint(_ title: String) -> some View {
        modifier(PluginHeaderHint(title: title))
    }

    func panelNavigationSurface() -> some View {
        modifier(PanelNavigationSurface())
    }

    @ViewBuilder
    func panelGlassButton(prominent: Bool = false, circular: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 8))
                    .controlSize(.regular)
            } else {
                self.buttonStyle(.glass)
                    .buttonBorderShape(circular ? .circle : .roundedRectangle(radius: 8))
                    .controlSize(.regular)
            }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) }
            else { self.buttonStyle(.bordered) }
        }
        #else
        if prominent { self.buttonStyle(.borderedProminent) }
        else { self.buttonStyle(.bordered) }
        #endif
    }

    @ViewBuilder
    package func panelWindowDragArea() -> some View {
        if #available(macOS 15, *) {
            self.gesture(WindowDragGesture())
        } else {
            self
        }
    }

    package func panelRegion(_ identifier: String) -> some View {
        #if DEBUG
        self.background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: PanelLayoutBoundsKey.self,
                    value: [identifier: geometry.frame(in: .named(PanelLayout.coordinateSpace))]
                )
            }
            .allowsHitTesting(false)
        }
        .accessibilityIdentifier(identifier)
        #else
        self.accessibilityIdentifier(identifier)
        #endif
    }
}

#if DEBUG
// 布局回归检查读取实际渲染坐标；Release 不安装这些测量视图。
struct PanelLayoutBoundsKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
#endif

private struct PanelNavigationSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background(PanelPalette.sidebar(scheme).opacity(reduceTransparency ? 1 : 0.96))
    }
}

struct PanelSearchField: View {
    @Binding var text: String
    var compact = false

    package var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("搜索插件", text: $text)
                .textFieldStyle(.plain)
                .accessibilityLabel("搜索插件")
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 12)
        .font(.system(size: compact ? 12 : 13))
        .frame(height: compact ? 30 : 36)
        .modifier(PanelSearchSurface(compact: compact))
    }
}

private struct PanelSearchSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var compact: Bool

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if !reduceTransparency, #available(macOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: compact ? 15 : 10))
        } else {
            content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: compact ? 15 : 10))
        }
        #else
        content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: compact ? 15 : 10))
        #endif
    }
}
