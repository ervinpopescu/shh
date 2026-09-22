import ShhCore
import SwiftUI
import UIKit
import XCTest
@testable import Shh

final class AppTypographyTests: XCTestCase {
    func testCompactWidthUsesDenserRowStyles() {
        XCTAssertEqual(
            AppTypography.textStyle(for: .rowTitle, horizontalSizeClass: .compact),
            .subheadline
        )
        XCTAssertEqual(
            AppTypography.textStyle(for: .rowSubtitle, horizontalSizeClass: .compact),
            .caption
        )
        XCTAssertEqual(
            AppTypography.textStyle(for: .rowMetadata, horizontalSizeClass: .compact),
            .caption2
        )
        XCTAssertEqual(
            AppTypography.textStyle(for: .sectionHeader, horizontalSizeClass: .compact),
            .subheadline
        )
    }

    func testRegularWidthKeepsStandardRowStyles() {
        XCTAssertEqual(
            AppTypography.textStyle(for: .rowTitle, horizontalSizeClass: .regular),
            .body
        )
        XCTAssertEqual(
            AppTypography.textStyle(for: .rowSubtitle, horizontalSizeClass: .regular),
            .footnote
        )
        XCTAssertEqual(
            AppTypography.textStyle(for: .rowMetadata, horizontalSizeClass: .regular),
            .caption
        )
        XCTAssertEqual(
            AppTypography.textStyle(for: .sectionHeader, horizontalSizeClass: .regular),
            .subheadline
        )
    }

    func testUnspecifiedWidthUsesRegularStyles() {
        XCTAssertEqual(
            AppTypography.textStyle(for: .rowTitle, horizontalSizeClass: nil),
            .body
        )
        XCTAssertEqual(
            AppTypography.textStyle(for: .rowSubtitle, horizontalSizeClass: nil),
            .footnote
        )
        XCTAssertEqual(
            AppTypography.textStyle(for: .rowMetadata, horizontalSizeClass: nil),
            .caption
        )
        XCTAssertEqual(
            AppTypography.textStyle(for: .sectionHeader, horizontalSizeClass: nil),
            .subheadline
        )
    }

    func testDynamicTypeRangesForSizeClasses() {
        XCTAssertEqual(
            AppTypography.dynamicTypeRange(for: .compact).upperBound,
            DynamicTypeSize.accessibility1
        )
        XCTAssertEqual(
            AppTypography.dynamicTypeRange(for: .regular).upperBound,
            DynamicTypeSize.accessibility3
        )
        XCTAssertEqual(
            AppTypography.dynamicTypeRange(for: nil).upperBound,
            DynamicTypeSize.accessibility3
        )
    }

    func testFontConstructionForCompactAndRegular() {
        // rowTitle uses semibold weight
        let compactTitleFont = AppTypography.font(
            for: .rowTitle,
            horizontalSizeClass: .compact
        )
        XCTAssertEqual(
            compactTitleFont,
            Font.system(.subheadline).weight(.semibold)
        )

        let regularTitleFont = AppTypography.font(
            for: .rowTitle,
            horizontalSizeClass: .regular
        )
        XCTAssertEqual(
            regularTitleFont,
            Font.system(.body).weight(.semibold)
        )

        let unspecifiedTitleFont = AppTypography.font(
            for: .rowTitle,
            horizontalSizeClass: nil
        )
        XCTAssertEqual(
            unspecifiedTitleFont,
            Font.system(.body).weight(.semibold)
        )

        // rowSubtitle
        let compactSubtitleFont = AppTypography.font(
            for: .rowSubtitle,
            horizontalSizeClass: .compact
        )
        XCTAssertEqual(compactSubtitleFont, Font.system(.caption))

        let regularSubtitleFont = AppTypography.font(
            for: .rowSubtitle,
            horizontalSizeClass: .regular
        )
        XCTAssertEqual(regularSubtitleFont, Font.system(.footnote))

        // rowMetadata
        let compactMetadataFont = AppTypography.font(
            for: .rowMetadata,
            horizontalSizeClass: .compact
        )
        XCTAssertEqual(compactMetadataFont, Font.system(.caption2))

        let regularMetadataFont = AppTypography.font(
            for: .rowMetadata,
            horizontalSizeClass: .regular
        )
        XCTAssertEqual(regularMetadataFont, Font.system(.caption))

        // sectionHeader
        let compactHeaderFont = AppTypography.font(
            for: .sectionHeader,
            horizontalSizeClass: .compact
        )
        XCTAssertEqual(
            compactHeaderFont,
            Font.system(.subheadline).weight(.semibold)
        )

        let regularHeaderFont = AppTypography.font(
            for: .sectionHeader,
            horizontalSizeClass: .regular
        )
        XCTAssertEqual(
            regularHeaderFont,
            Font.system(.subheadline).weight(.semibold)
        )

        let unspecifiedHeaderFont = AppTypography.font(
            for: .sectionHeader,
            horizontalSizeClass: nil
        )
        XCTAssertEqual(
            unspecifiedHeaderFont,
            Font.system(.subheadline).weight(.semibold)
        )
    }

    @MainActor
    func testAppTypographyViewModifiersRenderInHostingController() {
        let sampleView = VStack {
            Text("Header").appSectionHeader()
            Text("Title").appRowTitle()
            Text("Subtitle").appRowSubtitle()
            Text("Metadata").appRowMetadata()
        }
        .appDynamicTypeRange()

        // Compact environment
        let compactController = UIHostingController(
            rootView: sampleView.environment(
                \.horizontalSizeClass,
                Optional(UserInterfaceSizeClass.compact)
            )
        )
        compactController.loadViewIfNeeded()
        XCTAssertNotNil(compactController.view)

        // Regular environment
        let regularController = UIHostingController(
            rootView: sampleView.environment(
                \.horizontalSizeClass,
                Optional(UserInterfaceSizeClass.regular)
            )
        )
        regularController.loadViewIfNeeded()
        XCTAssertNotNil(regularController.view)
    }

    @MainActor
    func testHostRowExpandsForAccessibilityText() throws {
        let host = try Host(
            id: UUID(),
            name: "A host name that needs multiple lines at accessibility sizes",
            hostname: "host.example.com",
            port: 22,
            username: "admin"
        )
        let controller = UIHostingController(
            rootView: HostRow(host: host)
                .environment(\.horizontalSizeClass, Optional(UserInterfaceSizeClass.compact))
                .dynamicTypeSize(.accessibility5)
        )
        controller.view.bounds = CGRect(x: 0, y: 0, width: 320, height: 600)
        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()

        let fittedSize = controller.sizeThatFits(in: CGSize(width: 320, height: 600))
        XCTAssertGreaterThan(fittedSize.height, 44)
    }

    @MainActor
    func testHostRowBoundedByCompactDynamicTypeRange() throws {
        let host = try Host(
            id: UUID(),
            name: "A host name that needs multiple lines at accessibility sizes",
            hostname: "host.example.com",
            port: 22,
            username: "admin"
        )
        let unconstrainedController = UIHostingController(
            rootView: HostRow(host: host)
                .environment(\.horizontalSizeClass, Optional(UserInterfaceSizeClass.compact))
                .dynamicTypeSize(.accessibility5)
        )
        unconstrainedController.view.bounds = CGRect(x: 0, y: 0, width: 320, height: 600)
        unconstrainedController.loadViewIfNeeded()
        unconstrainedController.view.layoutIfNeeded()
        let unconstrainedHeight = unconstrainedController.sizeThatFits(in: CGSize(width: 320, height: 600)).height

        let clampedController = UIHostingController(
            rootView: HostRow(host: host)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .environment(\.horizontalSizeClass, Optional(UserInterfaceSizeClass.compact))
        )
        clampedController.view.bounds = CGRect(x: 0, y: 0, width: 320, height: 600)
        clampedController.loadViewIfNeeded()
        clampedController.view.layoutIfNeeded()
        let clampedHeight = clampedController.sizeThatFits(in: CGSize(width: 320, height: 600)).height

        XCTAssertGreaterThan(clampedHeight, 44)
        XCTAssertLessThanOrEqual(clampedHeight, unconstrainedHeight)
    }

    @MainActor
    func testHostRowRendersWithStandardAndAdversarialLongAddress() throws {
        let normalHost = try Host(
            id: UUID(),
            name: "Bastion",
            hostname: "bastion.example.com",
            port: 22,
            username: "admin"
        )
        let longAddressHost = try Host(
            id: UUID(),
            name: "Extreme Node",
            hostname:
                "very-long-subdomain-name-exceeding-compact-screen-width.infrastructure.internal.example.org",
            port: 2222,
            username: "cluster-admin-service-account"
        )

        for host in [normalHost, longAddressHost] {
            let rowView = HostRow(host: host)

            let compactController = UIHostingController(
                rootView: rowView.environment(
                    \.horizontalSizeClass,
                    Optional(UserInterfaceSizeClass.compact)
                )
            )
            compactController.loadViewIfNeeded()
            compactController.view.bounds = CGRect(x: 0, y: 0, width: 320, height: 60)
            compactController.view.layoutIfNeeded()
            XCTAssertNotNil(compactController.view)

            let regularController = UIHostingController(
                rootView: rowView.environment(
                    \.horizontalSizeClass,
                    Optional(UserInterfaceSizeClass.regular)
                )
            )
            regularController.loadViewIfNeeded()
            regularController.view.bounds = CGRect(x: 0, y: 0, width: 768, height: 60)
            regularController.view.layoutIfNeeded()
            XCTAssertNotNil(regularController.view)
        }
    }
}
