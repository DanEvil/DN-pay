//
//  BiometricAuthenticator.swift
//  MirWallet
//
//  Face ID / Touch ID confirmation before a payment is authorised.
//
//  The payment flow asks for confirmation at the moment the cryptogram is
//  about to be signed, so the user's biometric check covers the exact
//  transaction that is being approved.
//

import Foundation
import LocalAuthentication

final class BiometricAuthenticator {

    /// The biometric method the device offers.
    enum Method: String, Equatable {
        case faceID = "Face ID"
        case touchID = "Touch ID"
        case none = "—"

        /// Title for the confirmation prompt.
        var title: String {
            switch self {
            case .faceID: return "Подтвердите оплату через Face ID"
            case .touchID: return "Подтвердите оплату через Touch ID"
            case .none: return "Подтвердите оплату"
            }
        }
    }

    /// Maps a CoreAuthentication biometry type onto our own enum.
    static func method(for type: LABiometryType) -> Method {
        switch type {
        case .faceID: return .faceID
        case .touchID: return .touchID
        default: return .none
        }
    }

    /// The biometric method available on this device right now.
    static func availableMethod() -> Method {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                        error: &error) else {
            return .none
        }
        return method(for: context.biometryType)
    }

    /// Runs the biometric prompt.
    ///
    /// Returns the method that was used. If biometrics are unavailable or
    /// fail, the device passcode is accepted instead — a payment must not be
    /// blocked forever by a failed sensor.
    func confirm(reason: String) async throws -> Method {
        let context = LAContext()
        context.localizedCancelTitle = "Отмена"
        context.localizedFallbackTitle = "Ввести пароль"

        var error: NSError?
        let hasBiometrics = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                      error: &error)
        let method = Self.method(for: context.biometryType)

        let policy: LAPolicy = hasBiometrics
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication

        guard context.canEvaluatePolicy(policy, error: &error) else {
            throw error ?? LAError(.biometryNotAvailable)
        }

        let success = try await context.evaluatePolicy(policy, localizedReason: reason)
        guard success else {
            throw LAError(.authenticationFailed)
        }
        return method
    }
}
