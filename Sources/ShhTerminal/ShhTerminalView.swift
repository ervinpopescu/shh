#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit
import SwiftTerm
import ShhCore

private extension UIColor {
    convenience init(terminalColor: TerminalColor) {
        self.init(
            red: CGFloat(terminalColor.red) / 255,
            green: CGFloat(terminalColor.green) / 255,
            blue: CGFloat(terminalColor.blue) / 255,
            alpha: 1
        )
    }
}

public struct ShhTerminalView: UIViewRepresentable {
    @ObservedObject public var controller: ShhTerminalController

    public init(controller: ShhTerminalController) {
        self.controller = controller
    }

    public func makeUIView(context: Context) -> ShhInternalTerminalHostView {
        makeUIView(coordinator: context.coordinator)
    }

    internal func makeUIView(coordinator: Coordinator) -> ShhInternalTerminalHostView {
        if let existing = controller.persistentHostView {
            existing.controller = controller
            existing.terminalDelegate = coordinator
            controller.attachEngine(existing, firstResponder: existing)
            return existing
        }

        var options = TerminalOptions.default
        options.cols = controller.configuration.initialSize.columns
        options.rows = controller.configuration.initialSize.rows
        options.scrollback = controller.configuration.scrollbackLimit

        let view = ShhInternalTerminalHostView(
            frame: .zero,
            options: options,
            controller: controller
        )

        // CoreGraphics / CoreText rendering by default (Metal disabled)
        try? view.setUseMetal(false)

        view.terminalDelegate = coordinator
        controller.persistentHostView = view
        controller.attachEngine(view, firstResponder: view)

        return view
    }

    public func updateUIView(_ uiView: ShhInternalTerminalHostView, context: Context) {
        updateUIView(uiView, coordinator: context.coordinator)
    }

    internal func updateUIView(_ uiView: ShhInternalTerminalHostView, coordinator: Coordinator) {
        coordinator.controller = controller
        uiView.controller = controller
        if controller.attachedBridge == nil || controller.persistentHostView !== uiView {
            controller.persistentHostView = uiView
            uiView.terminalDelegate = coordinator
            controller.attachEngine(uiView, firstResponder: uiView)
        }
        uiView.updateSizeIfNeeded()
    }

    public static func dismantleUIView(_ uiView: ShhInternalTerminalHostView, coordinator: Coordinator) {
        _ = uiView.resignFirstResponder()
        if uiView.controller?.persistentHostView !== uiView {
            uiView.controller?.detachEngine(uiView)
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    public final class Coordinator: NSObject, TerminalViewDelegate {
        weak var controller: ShhTerminalController?

        init(controller: ShhTerminalController) {
            self.controller = controller
        }

        public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor [weak self] in
                self?.controller?.handleResize(columns: newCols, rows: newRows)
            }
        }

        public func setTerminalTitle(source: TerminalView, title: String) {
            Task { @MainActor [weak self] in
                self?.controller?.handleTitle(title)
            }
        }

        public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        public func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let payload = Data(data)
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    controller?.handleOutput(payload)
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.controller?.handleOutput(payload)
                }
            }
        }

        public func scrolled(source: TerminalView, position: Double) {}

        public func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {}

        public func bell(source: TerminalView) {
            Task { @MainActor [weak self] in
                self?.controller?.handleBell()
            }
        }

        public func clipboardCopy(source: TerminalView, content: Data) {}

        public func clipboardRead(source: TerminalView) -> Data? {
            nil
        }

        public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

public final class ShhInternalTerminalHostView: TerminalView, TerminalEngineBridge, TerminalFirstResponderBridge, UIGestureRecognizerDelegate {
    weak var controller: ShhTerminalController?
    private var lastAppliedBoundsSize: CGSize = .zero
    private var pinchBasePointSize: Double?
    internal var scrollGesture: UIPanGestureRecognizer!
    private var scrollReducer = TerminalScrollIntentReducer()
    private var scrollReducerState = TerminalScrollIntentReducer.State()
    private var suspendedMouseReporting = false
    private var previousAllowMouseReporting = true

    init(frame: CGRect, options: TerminalOptions, controller: ShhTerminalController) {
        self.controller = controller
        super.init(frame: frame, font: nil, options: options)
        self.inputAccessoryView = nil
        setupTapGesture()
        setupContextAwareScrollGesture()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupContextAwareScrollGesture() {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        gesture.maximumNumberOfTouches = 1
        gesture.cancelsTouchesInView = false
        gesture.delegate = self
        scrollGesture = gesture
        addGestureRecognizer(gesture)

        // Give this recognizer priority only when it is actually needed. When it
        // fails (plain primary scrollback or primary-screen tmux without mouse
        // reporting), UIScrollView retains native scrollback and no terminal
        // input is generated.
        panGestureRecognizer.require(toFail: gesture)
    }

    private func setupTapGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delegate = self
        addGestureRecognizer(pinch)
    }

    @objc private func handleTap() {
        if !isFirstResponder {
            _ = becomeFirstResponder()
        }
    }

    public override func gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === scrollGesture else { return true }
        let terminal = getTerminal()
        guard !hasActiveSelection else { return false }
        // Mouse reporting is application input. This is also required for a
        // primary-screen tmux session: its wheel binding, not SwiftTerm's local
        // scroll view, owns the session scrollback. With reporting disabled,
        // primary-screen scrolling falls through to the native scroll view.
        return terminal.mouseMode != .off || terminal.isCurrentBufferAlternate
    }

    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
        let phase: TerminalScrollGesture.Phase
        switch recognizer.state {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended: phase = .ended
        case .cancelled, .failed: phase = .cancelled
        default: return
        }
        let translation = recognizer.translation(in: self).y
        if recognizer.state == .changed {
            recognizer.setTranslation(.zero, in: self)
        }
        processScrollGesture(
            phase: phase,
            translationY: translation,
            velocityY: recognizer.velocity(in: self).y,
            location: recognizer.location(in: self)
        )
    }

    internal func processScrollGesture(
        phase: TerminalScrollGesture.Phase,
        translationY: Double,
        velocityY: Double = 0,
        location: CGPoint = .zero
    ) {
        let terminal = getTerminal()
        let mouseReporting = terminal.mouseMode != .off
        // Mouse wheel ticks represent touch movement through a stable viewport
        // grid, rather than every rendered glyph row. Without this normalization
        // a large phone/iPad terminal emits multiple wheel packets for one touch
        // update merely because its font creates more visible rows.
        let referenceRows = max(1, min(terminal.rows, 24))
        let rowHeight =
            mouseReporting
            ? max(1, bounds.height / CGFloat(referenceRows))
            : max(1, bounds.height / CGFloat(max(1, terminal.rows)))
        let context = TerminalScrollContext(
            surface: terminal.isCurrentBufferAlternate ? .alternate : .primary,
            mouseReporting: mouseReporting,
            rowHeight: rowHeight,
            rowCount: terminal.rows,
            copyModeFallbackAvailable: controller?.isCopyModeFallbackAvailable ?? false
        )
        if phase == .began && terminal.mouseMode != .off {
            previousAllowMouseReporting = allowMouseReporting
            allowMouseReporting = false
            suspendedMouseReporting = true
        }
        let event = TerminalScrollGesture(
            phase: phase,
            translationY: translationY,
            velocityY: velocityY
        )
        let intents = scrollReducer.reduce(event, context: context, state: &scrollReducerState)
        for intent in intents {
            applyScrollIntent(intent, terminal: terminal, at: location)
        }
        if phase == .ended || phase == .cancelled {
            if suspendedMouseReporting {
                allowMouseReporting = previousAllowMouseReporting
                suspendedMouseReporting = false
            }
        }
    }

    internal func applyScrollIntent(
        _ intent: TerminalScrollIntent,
        terminal: SwiftTerm.Terminal,
        at point: CGPoint
    ) {
        switch intent {
        case .native:
            break
        case .mouseWheel(let direction):
            let columnWidth = max(1, bounds.width / CGFloat(max(1, terminal.cols)))
            let rowHeight = max(1, bounds.height / CGFloat(max(1, terminal.rows)))
            let column = max(0, min(terminal.cols - 1, Int(floor(point.x / columnWidth))))
            let row = max(0, min(terminal.rows - 1, Int(floor(point.y / rowHeight))))
            // Use SwiftTerm's encoder rather than constructing CSI bytes here.
            // It selects SGR, UTF-8, URXVT, or legacy encoding negotiated by the
            // application, while keeping wheel buttons 4 and 5 (64 and 65).
            let button = direction == .up ? 4 : 5
            let buttonFlags = terminal.encodeButton(
                button: button,
                release: false,
                shift: false,
                meta: false,
                control: false
            )
            terminal.sendEvent(buttonFlags: buttonFlags, x: column, y: row)
        case .key(let key):
            let bytes: [UInt8]
            switch key {
            case .up:
                bytes =
                    terminal.applicationCursor
                    ? EscapeSequences.moveUpApp
                    : EscapeSequences.moveUpNormal
            case .down:
                bytes =
                    terminal.applicationCursor
                    ? EscapeSequences.moveDownApp
                    : EscapeSequences.moveDownNormal
            case .pageUp: bytes = EscapeSequences.cmdPageUp
            case .pageDown: bytes = EscapeSequences.cmdPageDown
            }
            insertText(String(decoding: bytes, as: UTF8.self))
        case .copyModeFallback:
            controller?.requestCopyModeFallback()
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            pinchBasePointSize = controller?.terminalFontSize
        case .changed:
            guard let controller else { return }
            controller.applyPinch(scale: recognizer.scale, basePointSize: pinchBasePointSize)
        case .ended, .cancelled, .failed:
            pinchBasePointSize = nil
        default:
            break
        }
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // SwiftTerm installs its own pan recognizer for mouse drags when any
        // mouse mode is enabled. Make that recognizer wait for this reducer so
        // a touch scroll emits wheel events, never a press/drag sequence.
        gestureRecognizer === scrollGesture
            && otherGestureRecognizer is UIPanGestureRecognizer
            && otherGestureRecognizer !== scrollGesture
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Pinch must not steal scrolling, selection, keyboard cursor movement, or
        // SwiftTerm's own touch handling. The context-aware pan is exclusive so
        // SwiftTerm's mouse-drag recognizer cannot add motion reports to a wheel.
        if gestureRecognizer === scrollGesture || otherGestureRecognizer === scrollGesture {
            let other =
                gestureRecognizer === scrollGesture
                ? otherGestureRecognizer
                : gestureRecognizer
            return other is UIPinchGestureRecognizer
        }
        return true
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
    }

    func updateSizeIfNeeded() {
        setNeedsLayout()
        layoutIfNeeded()
    }

    // MARK: - First Responder Recovery

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            controller?.updateFirstResponder(true)
        }
        return ok
    }

    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            controller?.updateFirstResponder(false)
        }
        return ok
    }

    public func requestFirstResponder() -> Bool {
        if window != nil {
            return becomeFirstResponder()
        }
        return false
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil && controller?.hasPendingFirstResponderRequest == true {
            if becomeFirstResponder() {
                controller?.updateFirstResponder(true)
            }
        }
    }

    // MARK: - Paste Handling

    public override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        if let controller {
            controller.handlePasteRequest(text)
        } else {
            super.paste(sender)
        }
    }

    // MARK: - Hardware keyboard zoom

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handledPress: UIPress?
        for press in presses {
            guard let key = press.key,
                  key.modifierFlags.contains(.command) else { continue }
            let shortcut: TerminalZoomShortcut?
            switch key.charactersIgnoringModifiers {
            case "+", "=":
                shortcut = .increase
            case "-", "_":
                shortcut = .decrease
            case "0":
                shortcut = .reset
            default:
                shortcut = nil
            }
            if let shortcut {
                _ = controller?.handleZoomShortcut(shortcut)
                handledPress = press
                break
            }
        }

        // Pass every non-zoom key through to SwiftTerm, including a mixed press
        // set, so terminal input is never silently discarded.
        if let handledPress {
            let passthrough = Set(presses.filter { $0 !== handledPress })
            if !passthrough.isEmpty {
                super.pressesBegan(passthrough, with: event)
            }
        } else {
            super.pressesBegan(presses, with: event)
        }
    }

    // MARK: - TerminalEngineBridge

    var bracketedPasteMode: Bool {
        getTerminal().bracketedPasteMode
    }

    var isAlternateScreenActive: Bool {
        getTerminal().isCurrentBufferAlternate
    }

    var currentSize: TerminalSize {
        TerminalSize(columns: getTerminal().cols, rows: getTerminal().rows)
    }

    func feed(data: Data) {
        let bytes = Array(data)
        feed(byteArray: bytes[...])
    }

    func resize(size: TerminalSize) {
        getTerminal().resize(cols: size.columns, rows: size.rows)
    }

    func changeScrollback(_ limit: Int) {
        getTerminal().changeScrollback(limit)
    }

    func setTheme(_ theme: TerminalThemePreset) {
        let palette = theme.palette
        nativeForegroundColor = UIColor(terminalColor: palette.foreground)
        nativeBackgroundColor = UIColor(terminalColor: palette.background)
        caretColor = UIColor(terminalColor: palette.cursor)
        caretTextColor = UIColor(terminalColor: palette.background)
        selectedTextBackgroundColor = UIColor(terminalColor: palette.selection)
        selectedTextForegroundColor = UIColor(terminalColor: palette.foreground)
        installColors(palette.ansi.map { color in
            SwiftTerm.Color(red8: UInt16(color.red), green8: UInt16(color.green), blue8: UInt16(color.blue))
        })
        backgroundColor = UIColor(terminalColor: palette.background)
        setNeedsDisplay()
    }

    func setFontSize(_ pointSize: Double) {
        font = UIFont.monospacedSystemFont(
            ofSize: TerminalFontSize.renderedPointSize(for: pointSize),
            weight: .regular
        )
        setNeedsLayout()
    }

    func recalculateSize() {
        setNeedsLayout()
        layoutIfNeeded()
    }

    func findNext(_ term: String) -> Bool {
        findNext(term, options: SearchOptions(), scrollToResult: true)
    }

    func findPrevious(_ term: String) -> Bool {
        findPrevious(term, options: SearchOptions(), scrollToResult: true)
    }

    func searchMatchSummary(_ term: String) -> (index: Int, total: Int) {
        searchMatchSummary(term, options: SearchOptions(), limit: 1000)
    }

    func currentTranscript(limit: Int) -> String {
        if let pageContent = accessibilityPageContent(), !pageContent.isEmpty {
            let lines = pageContent.components(separatedBy: "\n")
            return lines.suffix(limit).joined(separator: "\n")
        }
        let terminal = getTerminal()
        let dims = terminal.getDims()
        var lines: [String] = []
        for r in 0..<dims.rows {
            if let line = terminal.getLine(row: r) {
                lines.append(line.translateToString(trimRight: true))
            }
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.suffix(limit).joined(separator: "\n")
    }
}
#endif
