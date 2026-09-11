import Foundation
import Combine
import ShhCore
import SwiftTerm
#if canImport(UIKit) && canImport(SwiftUI)
import UIKit
import SwiftUI
#endif

public struct ShhTerminalConfiguration: Sendable {
    public var scrollbackLimit: Int
    public var resizeDebounceInterval: TimeInterval
    public var initialSize: TerminalSize

    public init(
        scrollbackLimit: Int = 5000,
        resizeDebounceInterval: TimeInterval = 0.150,
        initialSize: TerminalSize = TerminalSize(columns: 80, rows: 24)
    ) {
        self.scrollbackLimit = max(0, scrollbackLimit)
        self.resizeDebounceInterval = max(0, resizeDebounceInterval)
        self.initialSize = initialSize
    }
}

internal protocol TerminalEngineBridge: AnyObject {
    var bracketedPasteMode: Bool { get }
    var isAlternateScreenActive: Bool { get }
    var currentSize: TerminalSize { get }
    func feed(data: Data)
    func feed(text: String)
    func resize(size: TerminalSize)
    func changeScrollback(_ limit: Int)
    func findNext(_ term: String) -> Bool
    func findPrevious(_ term: String) -> Bool
    func searchMatchSummary(_ term: String) -> (index: Int, total: Int)
    func clearSearch()
    func selectAll()
    func selectNone()
    func getSelection() -> String?
    func currentTranscript(limit: Int) -> String
}

internal protocol TerminalFirstResponderBridge: AnyObject {
    var isFirstResponder: Bool { get }
    func requestFirstResponder() -> Bool
    func resignFirstResponder() -> Bool
}

@MainActor
public final class ShhTerminalController: ObservableObject {
    public static let defaultScrollbackLines = 5000
    public static let defaultResizeDebounceInterval: TimeInterval = 0.150

    public let configuration: ShhTerminalConfiguration

    @Published public private(set) var size: TerminalSize
    @Published public private(set) var title: String = ""
    @Published public private(set) var isFirstResponder: Bool = false

    public var onOutput: ((Data) -> Void)?
    public var onResize: ((TerminalSize) -> Void)?
    public var onTitleChanged: ((String) -> Void)?
    public var onBell: (() -> Void)?
    public var onFirstResponderChange: ((Bool) -> Void)?
    public var onRiskyPasteRequested: ((String) -> Void)?

    public var isMetalEnabled: Bool { false }

    public var bracketedPasteMode: Bool {
        if let attachedBridge {
            return attachedBridge.bracketedPasteMode
        }
        return headlessTerminal?.bracketedPasteMode ?? false
    }

    public var isAlternateScreenActive: Bool {
        if let attachedBridge {
            return attachedBridge.isAlternateScreenActive
        }
        return headlessTerminal?.isCurrentBufferAlternate ?? false
    }

    private var resizeDebouncer: ResizeDebouncer!
    private var headlessTerminal: SwiftTerm.Terminal?
    private var headlessDelegate: HeadlessBridgeDelegate?
    private var headlessSearchQuery: String = ""
    private var headlessSearchIndex: Int = 0
    private var headlessSelection: String? = nil
    internal weak var attachedBridge: TerminalEngineBridge?
    internal weak var firstResponderBridge: TerminalFirstResponderBridge?
    public private(set) var hasPendingFirstResponderRequest: Bool = false
    #if canImport(UIKit) && canImport(SwiftUI)
    internal var persistentHostView: ShhInternalTerminalHostView?
    #endif

    public init(configuration: ShhTerminalConfiguration = ShhTerminalConfiguration()) {
        self.configuration = configuration
        self.size = configuration.initialSize

        self.resizeDebouncer = ResizeDebouncer(
            delay: configuration.resizeDebounceInterval,
            queue: .main
        ) { [weak self] debouncedSize in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.size = debouncedSize
                self.onResize?(debouncedSize)
            }
        }

        setupHeadlessTerminal()
    }

    private func setupHeadlessTerminal() {
        let delegate = HeadlessBridgeDelegate(controller: self)
        self.headlessDelegate = delegate

        let options = TerminalOptions(
            cols: configuration.initialSize.columns,
            rows: configuration.initialSize.rows,
            scrollback: configuration.scrollbackLimit
        )
        self.headlessTerminal = SwiftTerm.Terminal(delegate: delegate, options: options)
    }

    // MARK: - Inbound Feeding

    public func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        if let attachedBridge {
            attachedBridge.feed(data: data)
        } else if let headlessTerminal {
            let bytes = Array(data)
            headlessTerminal.feed(buffer: bytes[...])
        }
    }

    public func feed(_ text: String) {
        guard !text.isEmpty else { return }
        if let attachedBridge {
            attachedBridge.feed(text: text)
        } else if let headlessTerminal {
            headlessTerminal.feed(text: text)
        }
    }

    // MARK: - Outbound Sending

    public func send(raw data: Data) {
        guard !data.isEmpty else { return }
        onOutput?(data)
    }

    public func send(text: String) {
        send(raw: Data(text.utf8))
    }

    public func send(key: TerminalKey) {
        let data = TerminalKeyEncoder.encode(key)
        send(raw: data)
    }

    public func paste(_ text: String) {
        let isBracketed = bracketedPasteMode
        let data = TerminalKeyEncoder.encodePaste(text, bracketed: isBracketed)
        send(raw: data)
    }

    public func handlePasteRequest(_ text: String) {
        if isRiskyUnbracketedPaste(text) {
            onRiskyPasteRequested?(text)
        } else {
            paste(text)
        }
    }

    public func isRiskyUnbracketedPaste(_ text: String) -> Bool {
        guard !bracketedPasteMode else { return false }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.contains("\n") && !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func reset() {
        resizeDebouncer.cancel()
        hasPendingFirstResponderRequest = false
        title = ""
        clearSearch()
        selectNone()
        feed("\u{1b}c")
        #if canImport(UIKit) && canImport(SwiftUI)
        persistentHostView = nil
        detachEngine()
        #endif
    }

    // MARK: - Search Affordances

    @discardableResult
    public func findNext(_ query: String) -> Bool {
        guard !query.isEmpty else {
            clearSearch()
            return false
        }
        if let attachedBridge {
            return attachedBridge.findNext(query)
        }
        return headlessFindNext(query)
    }

    @discardableResult
    public func findPrevious(_ query: String) -> Bool {
        guard !query.isEmpty else {
            clearSearch()
            return false
        }
        if let attachedBridge {
            return attachedBridge.findPrevious(query)
        }
        return headlessFindPrevious(query)
    }

    public func searchMatchSummary(_ query: String) -> (index: Int, total: Int) {
        guard !query.isEmpty else { return (0, 0) }
        if let attachedBridge {
            return attachedBridge.searchMatchSummary(query)
        }
        return headlessSearchMatchSummary(query)
    }

    public func clearSearch() {
        headlessSearchQuery = ""
        headlessSearchIndex = 0
        attachedBridge?.clearSearch()
    }

    private func headlessFindNext(_ query: String) -> Bool {
        let transcript = currentTranscript(limit: 5000)
        let occurrences = transcript.components(separatedBy: query).count - 1
        guard occurrences > 0 else {
            headlessSearchQuery = ""
            headlessSearchIndex = 0
            return false
        }
        if headlessSearchQuery != query {
            headlessSearchQuery = query
            headlessSearchIndex = 1
        } else {
            headlessSearchIndex = (headlessSearchIndex % occurrences) + 1
        }
        return true
    }

    private func headlessFindPrevious(_ query: String) -> Bool {
        let transcript = currentTranscript(limit: 5000)
        let occurrences = transcript.components(separatedBy: query).count - 1
        guard occurrences > 0 else {
            headlessSearchQuery = ""
            headlessSearchIndex = 0
            return false
        }
        if headlessSearchQuery != query {
            headlessSearchQuery = query
            headlessSearchIndex = occurrences
        } else {
            headlessSearchIndex = headlessSearchIndex <= 1 ? occurrences : (headlessSearchIndex - 1)
        }
        return true
    }

    private func headlessSearchMatchSummary(_ query: String) -> (index: Int, total: Int) {
        let transcript = currentTranscript(limit: 5000)
        let occurrences = transcript.components(separatedBy: query).count - 1
        guard occurrences > 0 else { return (0, 0) }
        if headlessSearchQuery != query {
            return (0, occurrences)
        }
        return (headlessSearchIndex, occurrences)
    }

    // MARK: - Selection Affordances

    public func selectAll() {
        if let attachedBridge {
            attachedBridge.selectAll()
        } else {
            headlessSelection = currentTranscript(limit: 5000)
        }
    }

    public func selectNone() {
        if let attachedBridge {
            attachedBridge.selectNone()
        } else {
            headlessSelection = nil
        }
    }

    public func getSelection() -> String? {
        if let attachedBridge {
            return attachedBridge.getSelection()
        }
        return headlessSelection
    }

    // MARK: - Transcript & Screen Text

    public func currentTranscript(limit: Int = 100) -> String {
        if let attachedBridge {
            return attachedBridge.currentTranscript(limit: limit)
        }
        guard let terminal = headlessTerminal else { return "" }
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

    // MARK: - Resize

    public func handleResize(columns: Int, rows: Int) {
        let newSize = TerminalSize(columns: columns, rows: rows)
        resizeDebouncer.receive(size: newSize)
    }

    public func flushResize() {
        resizeDebouncer.flush()
    }

    // MARK: - First Responder Recovery Hooks

    public func requestFirstResponder() {
        hasPendingFirstResponderRequest = true
        if let bridge = firstResponderBridge {
            let success = bridge.requestFirstResponder()
            if success {
                hasPendingFirstResponderRequest = false
                updateFirstResponder(true)
            }
        }
    }

    public func recoverFirstResponder() {
        requestFirstResponder()
    }

    public func resignFirstResponder() {
        hasPendingFirstResponderRequest = false
        if let bridge = firstResponderBridge {
            _ = bridge.resignFirstResponder()
        }
        updateFirstResponder(false)
    }

    internal func updateFirstResponder(_ active: Bool) {
        if active {
            hasPendingFirstResponderRequest = false
        }
        guard isFirstResponder != active else { return }
        isFirstResponder = active
        onFirstResponderChange?(active)
    }

    // MARK: - Internal Engine Bridge Handling

    internal func handleOutput(_ data: Data) {
        send(raw: data)
    }

    internal func handleTitle(_ newTitle: String) {
        guard self.title != newTitle else { return }
        self.title = newTitle
        self.onTitleChanged?(newTitle)
    }

    internal func handleBell() {
        self.onBell?()
    }

    internal func attachEngine(
        _ bridge: TerminalEngineBridge,
        firstResponder: TerminalFirstResponderBridge?
    ) {
        self.attachedBridge = bridge
        self.firstResponderBridge = firstResponder
        bridge.changeScrollback(configuration.scrollbackLimit)

        if hasPendingFirstResponderRequest {
            if firstResponder?.requestFirstResponder() == true {
                hasPendingFirstResponderRequest = false
                updateFirstResponder(true)
            }
        }
    }

    internal func detachEngine(_ bridge: (any TerminalEngineBridge)? = nil) {
        if let bridge {
            if self.attachedBridge === bridge {
                self.attachedBridge = nil
                self.firstResponderBridge = nil
            }
        } else {
            self.attachedBridge = nil
            self.firstResponderBridge = nil
        }
    }

    // MARK: - Access to Headless Terminal (Internal for Tests)

    internal var internalHeadlessTerminal: SwiftTerm.Terminal? {
        headlessTerminal
    }
}

private final class HeadlessBridgeDelegate: TerminalDelegate {
    weak var controller: ShhTerminalController?

    init(controller: ShhTerminalController) {
        self.controller = controller
    }

    func showCursor(source: SwiftTerm.Terminal) {}
    func hideCursor(source: SwiftTerm.Terminal) {}

    func setTerminalTitle(source: SwiftTerm.Terminal, title: String) {
        Task { @MainActor [weak self] in
            self?.controller?.handleTitle(title)
        }
    }

    func setTerminalIconTitle(source: SwiftTerm.Terminal, title: String) {}

    func windowCommand(source: SwiftTerm.Terminal, command: SwiftTerm.Terminal.WindowManipulationCommand) -> [UInt8]? {
        nil
    }

    func sizeChanged(source: SwiftTerm.Terminal) {
        let cols = source.cols
        let rows = source.rows
        Task { @MainActor [weak self] in
            self?.controller?.handleResize(columns: cols, rows: rows)
        }
    }

    func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) {
        let payload = Data(data)
        Task { @MainActor [weak self] in
            self?.controller?.handleOutput(payload)
        }
    }

    func scrolled(source: SwiftTerm.Terminal, yDisp: Int) {}
    func linefeed(source: SwiftTerm.Terminal) {}
    func bufferActivated(source: SwiftTerm.Terminal) {}
    func synchronizedOutputChanged(source: SwiftTerm.Terminal, active: Bool) {}

    func bell(source: SwiftTerm.Terminal) {
        Task { @MainActor [weak self] in
            self?.controller?.handleBell()
        }
    }

    func selectionChanged(source: SwiftTerm.Terminal) {}
    func isProcessTrusted(source: SwiftTerm.Terminal) -> Bool { true }
    func cellSizeInPixels(source: SwiftTerm.Terminal) -> (width: Int, height: Int)? { nil }
}
