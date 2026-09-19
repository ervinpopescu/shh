import Foundation

/// Builds the small set of controls that can be represented safely by the
/// dial. Unsupported Herdr actions are omitted rather than rendered as tmux
/// lookalikes. A missing focused object also produces no node.
public enum CommandDialMultiplexerMenu {
    public static func nodes(
        tmuxSessionID: TmuxSessionID?,
        tmuxPaneTarget: TmuxPaneTarget? = nil,
        tmuxWindowTarget: TmuxWindowTarget? = nil,
        herdrWorkspaceID: String? = nil,
        capabilities: MultiplexerCapabilities
    ) -> [DialNode] {
        var nodes: [DialNode] = []
        if capabilities.kind == .tmux {
            if let sessionID = tmuxSessionID {
                if capabilities.contains(.previousWindow) {
                    nodes.append(DialNode(id: "mux.tmux.previous-window", title: "Previous Window",
                                          systemImage: "chevron.left.2", action: .multiplexerControl(.tmux(.previousWindow(sessionID)))))
                }
                if capabilities.contains(.nextWindow) {
                    nodes.append(DialNode(id: "mux.tmux.next-window", title: "Next Window",
                                          systemImage: "chevron.right.2", action: .multiplexerControl(.tmux(.nextWindow(sessionID)))))
                }
                let target = tmuxPaneTarget ?? TmuxPaneTarget(sessionID: sessionID)
                if capabilities.contains(.directionalFocus) {
                    for direction in TmuxPaneDirection.allCases {
                        nodes.append(DialNode(id: "mux.tmux.focus.\(direction.rawValue)", title: "Focus \(direction.rawValue.capitalized)",
                                              systemImage: "arrow.\(direction.rawValue)", action: .multiplexerControl(.tmux(.focusPane(target, direction: direction)))))
                    }
                }
                if capabilities.contains(.horizontalSplit) {
                    nodes.append(DialNode(id: "mux.tmux.split.horizontal", title: "Split Horizontal", systemImage: "rectangle.split.1x2",
                                          action: .multiplexerControl(.tmux(.split(target, vertical: false)))))
                }
                if capabilities.contains(.verticalSplit) {
                    nodes.append(DialNode(id: "mux.tmux.split.vertical", title: "Split Vertical", systemImage: "rectangle.split.2x1",
                                          action: .multiplexerControl(.tmux(.split(target, vertical: true)))))
                }
                if capabilities.contains(.zoom) {
                    nodes.append(DialNode(id: "mux.tmux.zoom", title: "Toggle Zoom", systemImage: "arrow.up.left.and.arrow.down.right",
                                          action: .multiplexerControl(.tmux(.toggleZoom(target)))))
                }
                // choose-tree is interactive and must run through the terminal
                // PTY, not the command-exec channel used by dial controls.
                if capabilities.contains(.copyMode) {
                    nodes.append(DialNode(id: "mux.tmux.copy-mode", title: "Copy Mode", systemImage: "doc.on.clipboard",
                                          action: .multiplexerControl(.tmux(.copyMode(target)))))
                }
                if capabilities.contains(.closePane) {
                    nodes.append(DialNode(id: "mux.tmux.close-pane", title: "Close Pane", systemImage: "rectangle.badge.xmark",
                                          action: .multiplexerControl(.tmux(.closePane(target))), availability: .reviewRequired))
                }
            }
        }
        return nodes
    }
}
