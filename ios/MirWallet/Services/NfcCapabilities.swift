//
//  NfcCapabilities.swift
//  MirWallet
//
//  Separates "this phone has no NFC radio" from "this app is not allowed to
//  use NFC".
//
//  WHY THIS FILE EXISTS
//  -------------------
//  CoreNFC's own availability flags cannot tell those two cases apart:
//  `NFCReaderSession.readingAvailable` and `CardSession.isSupported` both
//  report false when the app's provisioning profile lacks the NFC
//  entitlements, regardless of what hardware is inside the phone.
//
//  A free Apple ID profile never carries `com.apple.developer.nfc.hce`, so a
//  perfectly capable iPhone used to be reported as "NFC not supported". The
//  hardware verdict here comes from the model identifier instead, and the
//  permission verdict comes from the entitlements the profile actually
//  granted.
//

import Foundation
import CoreNFC
import Darwin

enum NfcCapabilities {

    // MARK: - Hardware

    enum HardwareSupport: String, Equatable {
        case present
        case absent
        case unknown

        var title: String {
            switch self {
            case .present: return "есть"
            case .absent: return "нет"
            case .unknown: return "неизвестно"
            }
        }
    }

    /// Hardware model identifier, e.g. "iPhone14,4" for iPhone 13 mini.
    static var hardwareModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
    }

    /// Whether the hardware itself carries an NFC radio.
    static var hardwareSupport: HardwareSupport {
        hardwareSupport(forModel: hardwareModel)
    }

    /// iPhone models that carry an NFC radio while still using the iPhone10
    /// identifier family: iPhone X (10,3) and iPhone XS (10,6).
    ///
    /// The other iPhone10 models are the iPhone 8 and 8 Plus, which have no
    /// NFC. The family therefore cannot be judged by the major number alone.
    private static let nfcCapableIphone10Models: Set<String> = [
        "iPhone10,3",
        "iPhone10,6",
    ]

    /// Whether the given model identifier corresponds to a device with NFC.
    ///
    /// iPhone X (iPhone10,3) was the first iPhone with NFC. Every iPhone
    /// from the XS generation onwards has one; the iPhone 8 and 8 Plus do
    /// not.
    static func hardwareSupport(forModel model: String) -> HardwareSupport {
        guard model.hasPrefix("iPhone") else {
            // Only a few iPad models have NFC, and the mapping is not worth
            // hardcoding — report unknown rather than guess.
            return .unknown
        }

        let version = model.dropFirst("iPhone".count)
        let parts = version.split(separator: ",")
        guard parts.count == 2,
              let major = Int(parts[0]),
              let minor = Int(parts[1]) else {
            return .unknown
        }

        if major > 10 { return .present }
        if major == 10 {
            return nfcCapableIphone10Models.contains(model) ? .present : .absent
        }
        return .absent
    }

    // MARK: - Entitlements

    /// Entitlement keys the installed provisioning profile actually granted.
    struct ProfileEntitlements {
        var profileFound: Bool
        var keys: Set<String>

        var hasHCE: Bool {
            keys.contains("com.apple.developer.nfc.hce")
        }

        var hasTagReading: Bool {
            keys.contains("com.apple.developer.nfc.readersession.formats")
        }

        var hcePrefixes: Bool {
            keys.contains("com.apple.developer.nfc.hce.iso7816.select-identifier-prefixes")
        }

        /// Whether the app may be registered as the default contactless app.
        ///
        /// With this entitlement the system routes a terminal tap straight
        /// to the app, so the customer never has to open it.
        var hasDefaultContactlessApp: Bool {
            keys.contains("com.apple.developer.nfc.hce.default-contactless-app")
        }
    }

    /// Reads the entitlements from the embedded provisioning profile.
    ///
    /// Sideloading tools (Sideloadly, AltStore) embed the profile inside the
    /// app bundle, so this reflects what the app was actually signed with.
    static var profileEntitlements: ProfileEntitlements {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            return ProfileEntitlements(profileFound: false, keys: [])
        }

        // The profile is a CMS-signed plist. The XML payload sits inside the
        // DER blob verbatim, so it can be sliced out without verifying the
        // signature — this is a diagnostic, not a trust decision.
        guard let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>") else {
            return ProfileEntitlements(profileFound: false, keys: [])
        }

        let plistData = Data(text[start.lowerBound..<end.upperBound].utf8)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
              let root = plist as? [String: Any],
              let entitlements = root["Entitlements"] as? [String: Any] else {
            return ProfileEntitlements(profileFound: false, keys: [])
        }

        return ProfileEntitlements(profileFound: true, keys: Set(entitlements.keys))
    }

    // MARK: - Snapshot

    /// Everything the NFC tab needs to explain the current state.
    struct Snapshot {
        var model: String = ""
        var hardware: HardwareSupport = .unknown
        var readingAvailable: Bool?
        var cardSessionSupported: Bool?
        var cardSessionEligible: Bool?
        var profileFound: Bool = false
        var entitlementKeys: [String] = []
        var hasHCE: Bool = false
        var hasTagReading: Bool = false
        var hasDefaultContactlessApp: Bool = false
    }

    /// Captures the current NFC state.
    ///
    /// `CardSession.isEligible` is async, so it is read separately by the
    /// controller; everything else is synchronous.
    static func snapshot() -> Snapshot {
        var snapshot = Snapshot()
        snapshot.model = hardwareModel
        snapshot.hardware = hardwareSupport

        #if targetEnvironment(simulator)
        snapshot.readingAvailable = false
        snapshot.cardSessionSupported = false
        #else
        snapshot.readingAvailable = NFCReaderSession.readingAvailable
        snapshot.cardSessionSupported = CardSession.isSupported
        #endif

        let entitlements = profileEntitlements
        snapshot.profileFound = entitlements.profileFound
        snapshot.entitlementKeys = entitlements.keys.sorted()
        snapshot.hasHCE = entitlements.hasHCE
        snapshot.hasTagReading = entitlements.hasTagReading
        snapshot.hasDefaultContactlessApp = entitlements.hasDefaultContactlessApp

        return snapshot
    }
}
