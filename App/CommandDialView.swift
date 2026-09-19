import ShhCore
import ShhTerminal
import SwiftUI
import UIKit

struct SystemDialHaptics: DialHaptics {
    func emit(_ event: DialHapticEvent) {
        switch event {
        case .open, .selection, .boundary:
            UIImpactFeedbackGenerator(style: event == .boundary ? .soft : .light).impactOccurred()
        case .commit, .confirmation:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .failure:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

struct CommandDialTrigger: View {
    @Binding var isOpen: Bool
    let size: CommandDialSize
    let placement: CommandDialPlacement
    let accentColor: Color = .cyan
    let onOpen: () -> Void

    private var dimension: CGFloat { size == .compact ? 44 : 52 }

    var body: some View {
        Button {
            isOpen.toggle()
            if isOpen { onOpen() }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.9))
                    .overlay(Circle().stroke(Color.cyan.opacity(0.8), lineWidth: 1.5))
                Image(systemName: isOpen ? "xmark" : "waveform")
                    .font(.system(size: size == .compact ? 17 : 20, weight: .semibold))
                    .foregroundStyle(Color.cyan)
            }
            .frame(width: dimension, height: dimension)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("k", modifiers: [.command, .shift])
        .accessibilityLabel(isOpen ? "Close command dial" : "Open command dial")
        .accessibilityHint("Shows one-handed terminal controls")
        .accessibilityIdentifier("command-dial-trigger")
    }
}

struct CommandDialSurface: View {
    let model: CommandDialModel
    @Binding var navigation: CommandDialNavigation
    let placement: CommandDialPlacement
    let size: CommandDialSize
    let hostLabel: String
    let paneLabel: String
    let connectionStatus: String
    let onAction: (DialActionIdentifier) -> Void
    let onDismiss: () -> Void
    let haptics: any DialHaptics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedCategory: DialNode? {
        let categoryID = navigation.path.first ?? navigation.selectedNodeID
        guard let categoryID else { return nil }
        return model.roots.first { $0.id == categoryID }
    }

    private var activeCategoryID: String? {
        selectedCategory?.id ?? model.roots.first?.id
    }

    private var categorySelection: Binding<Int> {
        Binding(
            get: {
                guard let activeCategoryID,
                      let index = model.roots.firstIndex(where: { $0.id == activeCategoryID }) else { return 0 }
                return index
            },
            set: { index in
                guard model.roots.indices.contains(index) else { return }
                let category = model.roots[index]
                guard category.isEnabled else { return }
                navigation.selectCategory(category)
                haptics.emit(.selection)
            }
        )
    }

    init(model: CommandDialModel, navigation: Binding<CommandDialNavigation>, placement: CommandDialPlacement,
         size: CommandDialSize, hostLabel: String, paneLabel: String,
         connectionStatus: String = "Disconnected",
         onAction: @escaping (DialActionIdentifier) -> Void, onDismiss: @escaping () -> Void,
         haptics: any DialHaptics = NoopDialHaptics()) {
        self.model = model
        self._navigation = navigation
        self.placement = placement
        self.size = size
        self.hostLabel = hostLabel
        self.paneLabel = paneLabel
        self.connectionStatus = connectionStatus
        self.onAction = onAction
        self.onDismiss = onDismiss
        self.haptics = haptics
    }

    private var currentNodes: [DialNode] {
        if navigation.path.isEmpty {
            return selectedCategory?.children ?? model.roots
        }

        var nodes = model.roots
        for parentID in navigation.path {
            guard let parent = nodes.first(where: { $0.id == parentID }) else { return [] }
            nodes = parent.children
        }
        return nodes
    }

    private var currentTitle: String {
        guard navigation.path.last != nil else { return selectedCategory?.title ?? "Controls" }
        var nodes = model.roots
        var title = "Controls"
        for parentID in navigation.path {
            guard let parent = nodes.first(where: { $0.id == parentID }) else { break }
            title = parent.title
            nodes = parent.children
        }
        return title
    }

    private var breadcrumb: String {
        var titles = ["Shh", hostLabel, paneLabel]
        var nodes = model.roots
        for parentID in navigation.path {
            guard let parent = nodes.first(where: { $0.id == parentID }) else { break }
            titles.append(parent.title)
            nodes = parent.children
        }
        if navigation.path.isEmpty, let selectedCategory {
            titles.append(selectedCategory.title)
        }
        return titles.joined(separator: " / ")
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: placement == .leading ? .bottomLeading : .bottomTrailing) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }
                    .accessibilityHidden(true)

                panel
                    .frame(maxWidth: min(proxy.size.width * 0.82, size == .compact ? 390 : 540))
                    .frame(maxHeight: min(proxy.size.height * 0.58, size == .compact ? 420 : 520))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: placement == .leading ? .bottomLeading : .bottomTrailing)))
            }
            .padding(.leading, placement == .leading ? 8 : 0)
            .padding(.trailing, placement == .trailing ? 8 : 0)
            .padding(.bottom, 4)
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("command-dial-surface")
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                if !navigation.path.isEmpty {
                    Button {
                        navigation.back()
                        haptics.emit(.selection)
                    } label: {
                        Image(systemName: "chevron.left")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back from \(currentTitle)")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(breadcrumb)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                    Text("\(connectionStatus)  ·  \(currentTitle)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button("Done", action: onDismiss)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Dismiss command dial")
            }

            categoryBrowser

            if let selectedCategory, selectedCategory.children.isEmpty,
               !isContainerCategory(selectedCategory) {
                categoryActionButton(selectedCategory)
            } else if currentNodes.isEmpty {
                ContentUnavailableView("Nothing here yet", systemImage: "tray", description: Text("This control will be available in a later Shh update."))
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: size == .compact ? 108 : 140), spacing: 8)], spacing: 8) {
                        ForEach(currentNodes) { node in
                            nodeButton(node)
                        }
                    }
                    .padding(2)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.cyan.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        .accessibilityAddTraits(.isModal)
        .simultaneousGesture(
            DragGesture(minimumDistance: 44)
                .onEnded { value in handleDirectionalSwipe(value.translation) }
        )
        .accessibilityHint("Swipe up or diagonally up-left to open the next submenu")
    }

    private func handleDirectionalSwipe(_ translation: CGSize) {
        guard let direction = DialSwipeDirection.resolve(translation: translation),
              direction.opensSubmenu else { return }

        let openedNode = navigation.openNextSubmenu(using: direction, in: model)
        haptics.emit(openedNode == nil ? .boundary : .selection)
    }

    private var categoryBrowser: some View {
        TabView(selection: categorySelection) {
            ForEach(model.roots) { category in
                categoryCard(category)
                    .tag(model.roots.firstIndex(where: { $0.id == category.id }) ?? 0)
                    .padding(.horizontal, 2)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .frame(height: size == .compact ? 86 : 98)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command categories")
        .accessibilityHint("Swipe left or right to browse categories")
        .accessibilityIdentifier("command-dial-category-browser")
    }

    private func categoryCard(_ category: DialNode) -> some View {
        let isSelected = activeCategoryID == category.id
        return Button {
            activate(category)
        } label: {
            HStack(spacing: 10) {
                if let image = category.systemImage {
                    Image(systemName: image)
                        .font(.title3.weight(.semibold))
                        .frame(width: 28)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(category.title)
                        .font(.headline)
                    Text(isContainerCategory(category) ? "Swipe to browse, tap to open" : "Tap to use")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.cyan)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(category.isEnabled ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: size == .compact ? 64 : 76, alignment: .leading)
            .padding(.horizontal, 12)
            .background(
                isSelected ? Color.cyan.opacity(0.24) : Color.black.opacity(0.22),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.cyan.opacity(0.75) : Color.clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!category.isEnabled)
        .accessibilityLabel("\(category.title) category")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(category.children.isEmpty ? "Double tap to use" : "Double tap to open")
        .accessibilityIdentifier("command-dial-category-\(category.id.replacingOccurrences(of: ".", with: "-"))")
    }

    private func isContainerCategory(_ node: DialNode) -> Bool {
        if case .category = node.action { return true }
        return false
    }

    private func categoryActionButton(_ category: DialNode) -> some View {
        Button {
            activate(category)
        } label: {
            Label("Use \(category.title)", systemImage: category.systemImage ?? "play.fill")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: size == .compact ? 54 : 60)
        }
        .buttonStyle(.borderedProminent)
        .tint(.cyan)
        .accessibilityIdentifier("command-dial-category-action-\(category.id)")
    }

    @ViewBuilder
    private func nodeButton(_ node: DialNode) -> some View {
        Button {
            activate(node)
        } label: {
            HStack(spacing: 8) {
                if let image = node.systemImage {
                    Image(systemName: image).frame(width: 22)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.title).font(.system(size: size == .compact ? 14 : 16, weight: .semibold))
                        .multilineTextAlignment(.leading)
                    if let subtitle = node.subtitle {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if case .unavailable(let reason) = node.availability {
                        Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if !node.children.isEmpty { Image(systemName: "chevron.right").font(.caption2) }
            }
            .foregroundStyle(node.isEnabled ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: size == .compact ? 52 : 60, alignment: .leading)
            .padding(.horizontal, 10)
            .background((navigation.selectedNodeID == node.id ? Color.cyan.opacity(0.24) : Color.black.opacity(0.22)), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!node.isEnabled)
        .accessibilityLabel(accessibilityLabel(for: node))
        .accessibilityIdentifier("command-dial-node-\(node.id.replacingOccurrences(of: ".", with: "-"))")
    }

    private func activate(_ node: DialNode) {
        guard node.isEnabled else { return }
        haptics.emit(.commit)
        if !node.children.isEmpty {
            navigation.enter(node)
            haptics.emit(.selection)
        } else {
            onAction(node.action)
        }
    }

    private func accessibilityLabel(for node: DialNode) -> String {
        switch node.availability {
        case .available: return node.title
        case .reviewRequired: return "\(node.title), approval required"
        case .blocked(let reason): return "\(node.title), blocked: \(reason)"
        case .unavailable(let reason): return "\(node.title), unavailable: \(reason)"
        }
    }

}
