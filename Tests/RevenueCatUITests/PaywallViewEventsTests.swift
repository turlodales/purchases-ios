//
//  Copyright RevenueCat Inc. All Rights Reserved.
//
//  Licensed under the MIT License (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      https://opensource.org/licenses/MIT
//
//  PaywallViewEventsTests.swift
//
//  Created by Nacho Soto on 9/7/23.
// swiftlint:disable type_name

import Nimble
import RevenueCat
@testable import RevenueCatUI
import SwiftUI
import XCTest

#if !os(watchOS) && !os(macOS)

@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
final class PaywallViewEventsFullscreenLightModeTests: BasePaywallViewEventsTests {
    override var mode: PaywallViewMode { .fullScreen }
    override var scheme: ColorScheme { .light }
}

@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
final class PaywallViewEventsFooterDarkModeTests: BasePaywallViewEventsTests {
    override var mode: PaywallViewMode { .footer }
    override var scheme: ColorScheme { .dark }
}

@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
@MainActor
class BasePaywallViewEventsTests: TestCase {

    // To be overridden by subclasses
    var mode: PaywallViewMode { fatalError("Must override") }
    var scheme: ColorScheme { fatalError("Must override") }

    private var events: [PaywallEvent] = []
    private var handler: PurchaseHandler!

    /// Prevents XCTest from running this base class directly.
    /// This class is intended to be subclassed for concrete test cases,
    /// each providing their own `mode` and `scheme` configurations.
    /// By returning an empty test suite for the base class,
    /// we ensure that shared test logic is only executed through subclasses.
    override class var defaultTestSuite: XCTestSuite {
        return self == BasePaywallViewEventsTests.self
            ? XCTestSuite(name: "BasePaywallViewEventsTests")
            : super.defaultTestSuite
    }

    private var impressionEventExpectation: XCTestExpectation!
    private var closeEventExpectation: XCTestExpectation!

    override func setUp() {
        super.setUp()

        self.continueAfterFailure = false

        self.handler =
            .cancelling()
            .map { _ in
                return { [weak self] event in
                    await self?.track(event)
                }
            }
        self.impressionEventExpectation = XCTestExpectation(description: "Impression event")
        self.closeEventExpectation = .init(description: "Close event")
    }

    func testPaywallImpressionEvent() async throws {

        try await self.runDuringViewLifetime {
            await Task.yield()
        }

        await self.fulfillment(of: [impressionEventExpectation], timeout: 3)

        expect(self.events)
            .to(containElementSatisfying { $0.eventType == .impression })

        let event = try XCTUnwrap(self.events.first { $0.eventType == .impression })
        self.verifyEventData(event.data)
    }

    func testPaywallCloseEvent() async throws {
        try await self.runDuringViewLifetime {
            await Task.yield()
        }
        await self.waitForCloseEvent()

        expect(self.events).to(haveCount(2))
        expect(self.events).to(containElementSatisfying { $0.eventType == .close })

        let event = try XCTUnwrap(self.events.first { $0.eventType == .impression })
        self.verifyEventData(event.data)
    }

    func testCloseEventHasSameSessionID() async throws {
        try await self.runDuringViewLifetime {
            await Task.yield()
        }
        await self.waitForCloseEvent()

        expect(self.events).to(haveCount(2))
        expect(self.events.map(\.eventType)) == [.impression, .close]
        expect(Set(self.events.map(\.data.sessionIdentifier))).to(haveCount(1))
    }

    func testCancelledPurchase() async throws {
        try await self.runDuringViewLifetime {
            _ = try await self.handler.purchase(package: try XCTUnwrap(Self.offering.monthly))
        }

        await self.waitForCloseEvent()

        expect(self.events).to(haveCount(3))
        expect(self.events.map(\.eventType)).to(contain([.impression, .cancel, .close]))
        expect(Set(self.events.map(\.data.sessionIdentifier))).to(haveCount(1))

        let data = try XCTUnwrap(self.events.first { $0.eventType == .cancel }).data
        self.verifyEventData(data)
    }

    func testDifferentPaywallsCreateSeparateSessionIdentifiers() async throws {
        self.closeEventExpectation.expectedFulfillmentCount = 2

        try await self.runDuringViewLifetime {
            await Task.yield()
        }
        try await self.runDuringViewLifetime {
            await Task.yield()
        }

        await self.waitForCloseEvent()

        expect(self.events).to(haveCount(4))
        expect(self.events.map(\.eventType)) == [.impression, .close, .impression, .close]
        expect(Set(self.events.map(\.data.sessionIdentifier))).to(haveCount(2))
    }

    private static let offering = TestData.offeringWithNoIntroOffer

}

// MARK: -

@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
private extension BasePaywallViewEventsTests {

    /// Invokes `createView` and runs the given `closure` during the lifetime of the view.
    /// Returns after the view has been completly removed from the hierarchy.
    func runDuringViewLifetime(
        _ closure: @escaping () async throws -> Void
    ) async throws {
        // Create a `Task` to run inside of an `autoreleasepool`.
        try await Task {
            let dispose = try self.createView()
                .addToHierarchy()

            try await Task.sleep(nanoseconds: 3 * 1_000_000)

            try await closure()
            dispose()
        }.value
    }

    func track(_ event: PaywallEvent) {
        self.events.append(event)

        switch event {
        case .impression: self.impressionEventExpectation.fulfill()
        case .cancel: break
        case .close: self.closeEventExpectation.fulfill()
        }
    }

    func createView() -> some View {
        PaywallView(
            configuration: .init(
                offering: Self.offering.withLocalImages,
                customerInfo: TestData.customerInfo,
                mode: self.mode,
                introEligibility: .producing(eligibility: .eligible),
                purchaseHandler: self.handler
            )
        )
        .environment(\.colorScheme, self.scheme)
    }

    func verifyEventData(_ data: PaywallEvent.Data) {
        expect(data.offeringIdentifier) == Self.offering.identifier
        expect(data.paywallRevision) == Self.offering.paywall?.revision
        expect(data.displayMode) == self.mode
        expect(data.localeIdentifier) == Locale.current.identifier
        expect(data.darkMode) == (self.scheme == .dark)
    }

    func waitForCloseEvent() async {
        await self.fulfillment(of: [self.closeEventExpectation], timeout: 3)
    }

}

private extension PaywallViewMode {

    static var random: Self {
        return Self.allCases.randomElement()!
    }

}

private extension PaywallEvent {

    enum EventType {

        case impression
        case cancel
        case close

    }

    var eventType: EventType {
        switch self {
        case .impression: return .impression
        case .cancel: return .cancel
        case .close: return .close
        }
    }

}

#endif
