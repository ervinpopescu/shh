#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit
import SwiftTerm
import ShhCore

public struct ShhTerminalView: UIViewRepresentable {
    @ObservedObject public var controller: ShhTerminalController

    public init(controller: ShhTerminalController) {
        self.controller = controller
    }

    public func makeUIView(context: Context) -> ShhInternalTerminalHostView {
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

        view.terminalDelegate = context.coordinator
        controller.attachEngine(view, firstResponder: view)

        return view
    }

    public func updateUIView(_ uiView: ShhInternalTerminalHostView, context: Context) {
        uiView.updateSizeIfNeeded()
    }

    public static func dismantleUIView(_ uiView: ShhInternalTerminalHostView, coordinator: Coordinator) {
        uiView.controller?.detachEngine()
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
            Task { @MainActor [weak self] in
                self?.controller?.handleOutput(payload)
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

public final class ShhInternalTerminalHostView: TerminalView, TerminalEngineBridge, TerminalFirstResponderBridge {
    weak var controller: ShhTerminalController?
    private var lastAppliedBoundsSize: CGSize = .zero

    init(frame: CGRect, options: TerminalOptions, controller: ShhTerminalController) {
        self.controller = controller
        super.init(frame: frame, font: nil, options: options)
        setupTapGesture()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupTapGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    @objc private func handleTap() {
        if !isFirstResponder {
            _ = becomeFirstResponder()
        }
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
            _ = becomeFirstResponder()
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
}
#endif
