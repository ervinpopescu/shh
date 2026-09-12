import SwiftUI
import UIKit

/// Reusable presentation modifier for editor and modal sheets on iPadOS and iOS.
///
/// For iOS 17+, editor sheets prioritize content scrolling over sheet dismissal,
/// present at large detents by default to prevent squished floating sheet presentation on iPad,
/// show scroll indicators, and dismiss the software keyboard interactively during scrolling.
public struct EditorSheetPresentationModifier: ViewModifier {
    public let detents: Set<PresentationDetent>
    public let dragIndicator: Visibility

    public init(
        detents: Set<PresentationDetent> = [.large],
        dragIndicator: Visibility = .visible
    ) {
        self.detents = detents
        self.dragIndicator = dragIndicator
    }

    public func body(content: Content) -> some View {
        content
            .presentationDetents(detents)
            .presentationDragIndicator(dragIndicator)
            .presentationContentInteraction(.scrolls)
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.visible)
            .background(SheetPresentationAdapter())
    }
}

public extension View {
    /// Applies standardized editor sheet presentation configuration for iPadOS and iOS 17+.
    ///
    /// Sets a large presentation detent, enables scroll-first presentation content interaction,
    /// shows scroll indicators, and interactively dismisses the keyboard during scrolling.
    func editorSheetPresentation(
        detents: Set<PresentationDetent> = [.large],
        dragIndicator: Visibility = .visible
    ) -> some View {
        modifier(EditorSheetPresentationModifier(
            detents: detents,
            dragIndicator: dragIndicator
        ))
    }
}

// MARK: - UIKit Bridge for iPadOS Large Sheets

private struct SheetPresentationAdapter: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> AdapterController {
        AdapterController()
    }

    func updateUIViewController(_ uiViewController: AdapterController, context: Context) {
        uiViewController.configure()
    }

    final class AdapterController: UIViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            view.isHidden = true
            view.isUserInteractionEnabled = false
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            configure()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            configure()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            configure()
        }

        func configure() {
            var responder: UIResponder? = self
            while let current = responder {
                if let vc = current as? UIViewController {
                    if let sheet = vc.sheetPresentationController {
                        sheet.prefersPageSizing = true
                        sheet.prefersGrabberVisible = true
                        return
                    }
                }
                responder = current.next
            }
        }
    }
}
