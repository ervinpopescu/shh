import SwiftUI

/// Shared semantic styles for content rows and section headers that scale adaptively
/// based on horizontal size class without opting out of Dynamic Type.
enum AppTypography {
    enum Style: Equatable {
        case rowTitle
        case rowSubtitle
        case rowMetadata
        case sectionHeader
    }

    static func dynamicTypeRange(
        for horizontalSizeClass: UserInterfaceSizeClass?
    ) -> PartialRangeThrough<DynamicTypeSize> {
        horizontalSizeClass == .compact ? ...DynamicTypeSize.accessibility1 : ...DynamicTypeSize.accessibility3
    }

    static func textStyle(
        for style: Style,
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> Font.TextStyle {
        let isCompact = horizontalSizeClass == .compact
        switch style {
        case .rowTitle:
            return isCompact ? .subheadline : .body
        case .rowSubtitle:
            return isCompact ? .caption : .footnote
        case .rowMetadata:
            return isCompact ? .caption2 : .caption
        case .sectionHeader:
            return .subheadline
        }
    }

    static func font(
        for style: Style,
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> Font {
        let font = Font.system(
            textStyle(for: style, horizontalSizeClass: horizontalSizeClass)
        )
        switch style {
        case .rowTitle, .sectionHeader:
            return font.weight(.semibold)
        case .rowSubtitle, .rowMetadata:
            return font
        }
    }
}

private struct AppTypographyModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let style: AppTypography.Style

    func body(content: Content) -> some View {
        content.font(
            AppTypography.font(for: style, horizontalSizeClass: horizontalSizeClass)
        )
    }
}

private struct AppDynamicTypeRangeModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        content.dynamicTypeSize(AppTypography.dynamicTypeRange(for: horizontalSizeClass))
    }
}

extension View {
    func appDynamicTypeRange() -> some View {
        modifier(AppDynamicTypeRangeModifier())
    }

    func appRowTitle() -> some View {
        modifier(AppTypographyModifier(style: .rowTitle))
    }

    func appRowSubtitle() -> some View {
        modifier(AppTypographyModifier(style: .rowSubtitle))
    }

    func appRowMetadata() -> some View {
        modifier(AppTypographyModifier(style: .rowMetadata))
    }

    func appSectionHeader() -> some View {
        modifier(AppTypographyModifier(style: .sectionHeader))
            .textCase(nil)
    }
}
