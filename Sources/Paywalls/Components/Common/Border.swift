//
//  Copyright RevenueCat Inc. All Rights Reserved.
//
//  Licensed under the MIT License (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      https://opensource.org/licenses/MIT
//
//  Border.swift
//
//  Created by Josh Holtz on 9/30/24.
// swiftlint:disable missing_docs

import Foundation

#if PAYWALL_COMPONENTS

public extension PaywallComponent {

    struct Border: Codable, Sendable, Hashable {

        public let color: ColorInfo
        public let width: Double

        public init(color: PaywallComponent.ColorInfo, width: Double) {
            self.color = color
            self.width = width
        }

    }

}

#endif