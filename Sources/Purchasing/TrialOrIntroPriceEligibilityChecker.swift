//
//  Copyright RevenueCat Inc. All Rights Reserved.
//
//  Licensed under the MIT License (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      https://opensource.org/licenses/MIT
//
//  IntroTrialOrIntroductoryPriceEligibilityChecker.swift
//
//  Created by César de la Vega on 8/31/21.

import Foundation
import StoreKit

typealias ReceiveIntroEligibilityBlock = ([String: IntroEligibility]) -> Void

/// A type that can determine `IntroEligibility` for products.
protocol TrialOrIntroPriceEligibilityCheckerType: Sendable {

    func checkEligibility(productIdentifiers: Set<String>, completion: @escaping ReceiveIntroEligibilityBlock)
}

class TrialOrIntroPriceEligibilityChecker: TrialOrIntroPriceEligibilityCheckerType {

    private var appUserID: String { self.currentUserProvider.currentAppUserID }

    private let systemInfo: SystemInfo
    private let receiptFetcher: ReceiptFetcher
    private let introEligibilityCalculator: IntroEligibilityCalculator
    private let backend: Backend
    private let currentUserProvider: CurrentUserProvider
    private let operationDispatcher: OperationDispatcher
    private let productsManager: ProductsManagerType

    init(
        systemInfo: SystemInfo,
        receiptFetcher: ReceiptFetcher,
        introEligibilityCalculator: IntroEligibilityCalculator,
        backend: Backend,
        currentUserProvider: CurrentUserProvider,
        operationDispatcher: OperationDispatcher,
        productsManager: ProductsManagerType
    ) {
        self.systemInfo = systemInfo
        self.receiptFetcher = receiptFetcher
        self.introEligibilityCalculator = introEligibilityCalculator
        self.backend = backend
        self.currentUserProvider = currentUserProvider
        self.operationDispatcher = operationDispatcher
        self.productsManager = productsManager
    }

    func checkEligibility(productIdentifiers: Set<String>,
                          completion: @escaping ReceiveIntroEligibilityBlock) {
        guard !self.systemInfo.dangerousSettings.uiPreviewMode else {
            // No check eligibility request should happen in UI preview mode.
            // Thus, the eligibility status for all product identifiers are set to `.unknown`
            let result = productIdentifiers.reduce(into: [:]) { resultDict, productId in
                resultDict[productId] = IntroEligibility(eligibilityStatus: IntroEligibilityStatus.unknown)
            }
            completion(result)
            return
        }

        guard !productIdentifiers.isEmpty else {
            Logger.warn(Strings.eligibility.check_eligibility_no_identifiers)
            completion([:])
            return
        }

        // Extracting and wrapping the completion block from the async call
        // to avoid having to mark ReceiveIntroEligibilityBlock as @Sendable
        // up to the public API thus making a breaking change.
        let completionBlock: ReceiveIntroEligibilityBlock = { result in
            self.operationDispatcher.dispatchOnMainActor {
                completion(result)
            }
        }

        if #available(iOS 15.0, tvOS 15.0, watchOS 8.0, macOS 12.0, *),
           self.systemInfo.storeKitVersion.isStoreKit2EnabledAndAvailable {
            Async.call(with: completionBlock) {
                do {
                    return try await self.sk2CheckEligibility(productIdentifiers)
                } catch {
                    Logger.appleError(Strings.eligibility.unable_to_get_intro_eligibility_for_user(error: error))

                    return productIdentifiers.reduce(into: [:]) { resultDict, productId in
                        resultDict[productId] = IntroEligibility(eligibilityStatus: IntroEligibilityStatus.unknown)
                    }
                }
            }
        } else {
            self.sk1CheckEligibility(productIdentifiers) { result in
                self.operationDispatcher.dispatchOnMainActor {
                    completion(result)
                }
            }
        }
    }

    func sk1CheckEligibility(_ productIdentifiers: Set<String>,
                             completion: @escaping ReceiveIntroEligibilityBlock) {
        // We don't want to refresh receipts because it will likely prompt the user for their credentials,
        // and intro eligibility is triggered programmatically.
        self.receiptFetcher.receiptData(refreshPolicy: .never) { data, _ in
            if let data = data {
                self.sk1CheckEligibility(with: data,
                                         productIdentifiers: productIdentifiers) { eligibility in
                    self.operationDispatcher.dispatchOnMainActor {
                        completion(eligibility)
                    }
                }
            } else {
                self.getIntroEligibility(with: data ?? Data(),
                                         productIdentifiers: productIdentifiers) { eligibility in
                    self.operationDispatcher.dispatchOnMainActor {
                        completion(eligibility)
                    }
                }
            }
        }
    }

    @available(iOS 15.0, tvOS 15.0, watchOS 8.0, macOS 12.0, *)
    func sk2CheckEligibility(_ productIdentifiers: Set<String>) async throws -> [String: IntroEligibility] {
        var introDictionary: [String: IntroEligibility] = productIdentifiers.dictionaryWithValues { _ in
                .init(eligibilityStatus: .unknown)
        }

        let products = try await self.productsManager.sk2Products(withIdentifiers: productIdentifiers)
        for sk2StoreProduct in products {
            let sk2Product = sk2StoreProduct.underlyingSK2Product

            let eligibilityStatus: IntroEligibilityStatus

            if let subscription = sk2Product.subscription, subscription.introductoryOffer != nil {
                let isEligible = await TimingUtil.measureAndLogIfTooSlow(
                    threshold: .introEligibility,
                    message: Strings.eligibility.sk2_intro_eligibility_too_slow.description) {
                        return await subscription.isEligibleForIntroOffer
                    }
                eligibilityStatus = isEligible ? .eligible : .ineligible
            } else {
                eligibilityStatus = .noIntroOfferExists
            }

            introDictionary[sk2StoreProduct.productIdentifier] = .init(eligibilityStatus: eligibilityStatus)
        }

        return introDictionary
    }

}

/// Default overload implementation that takes a single `StoreProductType`.
extension TrialOrIntroPriceEligibilityCheckerType {

    func checkEligibility(product: StoreProductType, completion: @escaping (IntroEligibilityStatus) -> Void) {
        self.checkEligibility(productIdentifiers: [product.productIdentifier]) { eligibility in
            completion(eligibility[product.productIdentifier]?.status ?? .unknown)
        }
    }

}

// MARK: - Implementations

private extension TrialOrIntroPriceEligibilityChecker {

    func sk1CheckEligibility(with receiptData: Data,
                             productIdentifiers: Set<String>,
                             completion: @escaping ReceiveIntroEligibilityBlock) {
        introEligibilityCalculator
            .checkEligibility(with: receiptData,
                              productIdentifiers: productIdentifiers) { receivedEligibility, error in
                if let error = error {
                    Logger.error(Strings.receipt.parse_receipt_locally_error(error: error))
                    self.getIntroEligibility(with: receiptData,
                                             productIdentifiers: productIdentifiers,
                                             completion: completion)
                    return
                }

                let convertedEligibility = receivedEligibility.mapValues(IntroEligibility.init)

                self.operationDispatcher.dispatchOnMainThread {
                    completion(convertedEligibility)
                }
            }
    }

    func getIntroEligibility(with receiptData: Data,
                             productIdentifiers: Set<String>,
                             completion: @escaping ReceiveIntroEligibilityBlock) {
        if #available(iOS 11.2, macOS 10.13.2, macCatalyst 13.0, tvOS 11.2, watchOS 6.2, *) {
            // Products that don't have an introductory discount don't need to be sent to the backend
            // Step 1: Filter out products without introductory discount and give .noIntroOfferExists status
            // Step 2: Send products without eligibility status to backend
            // Step 3: Merge results from step 1 and step 2
            self.productsWithKnownIntroEligibilityStatus(productIdentifiers: productIdentifiers) { onDeviceResults in
                let nilProductIdentifiers = productIdentifiers.filter { productIdentifier in
                    return onDeviceResults[productIdentifier] == nil
                }

                self.getIntroEligibilityFromBackend(with: receiptData,
                                                    productIdentifiers: nilProductIdentifiers) { backendResults in
                    let results = onDeviceResults + backendResults
                    completion(results)
                }
            }
        } else {
            self.getIntroEligibilityFromBackend(with: receiptData,
                                                productIdentifiers: productIdentifiers,
                                                completion: completion)
        }
    }

}

extension TrialOrIntroPriceEligibilityChecker {

    @available(iOS 11.2, macOS 10.13.2, macCatalyst 13.0, tvOS 11.2, watchOS 6.2, *)
    func productsWithKnownIntroEligibilityStatus(productIdentifiers: Set<String>,
                                                 completion: @escaping ReceiveIntroEligibilityBlock) {
        self.productsManager.products(withIdentifiers: productIdentifiers) { products in
            let eligibility: [(String, IntroEligibility)] = Array(products.value ?? [])
                .filter { $0.introductoryDiscount == nil }
                .map { ($0.productIdentifier, IntroEligibility(eligibilityStatus: .noIntroOfferExists)) }

            let productIdsToIntroEligibleStatus = Dictionary(uniqueKeysWithValues: eligibility)
            completion(productIdsToIntroEligibleStatus)
        }
    }

    func getIntroEligibilityFromBackend(with receiptData: Data,
                                        productIdentifiers: Set<String>,
                                        completion: @escaping ReceiveIntroEligibilityBlock) {
        if productIdentifiers.isEmpty {
            completion([:])
            return
        }

        self.backend.offerings.getIntroEligibility(appUserID: self.appUserID,
                                                   receiptData: receiptData,
                                                   productIdentifiers: productIdentifiers) { backendResult, error in
            let result: [String: IntroEligibility] = {
                if let error = error {
                    Logger.error(Strings.eligibility.unable_to_get_intro_eligibility_for_user(error: error))
                    return productIdentifiers
                        .dictionaryWithValues { _ in IntroEligibility(eligibilityStatus: .unknown) }
                } else {
                    return backendResult
                }
            }()

            self.operationDispatcher.dispatchOnMainThread {
                completion(result)
            }
        }
    }

}

// @unchecked because:
// - Class is not `final` (it's mocked). This implicitly makes subclasses `Sendable` even if they're not thread-safe.
extension TrialOrIntroPriceEligibilityChecker: @unchecked Sendable {}
