//
//  WalletStore.swift
//  MirWallet
//
//  The saved cards, and which one is the primary.
//
//  A wallet entry keeps only what a real wallet keeps: the token, the DPAN,
//  the last four digits, the brand and the expiry. The PAN and the CVV are
//  never written to disk — they live only for the length of a transaction,
//  exactly like a real card tokenisation.
//

import Foundation

// MARK: - Card

struct WalletCard: Codable, Identifiable, Equatable {

    /// Token identifier, unique per card. Doubles as the entry id.
    let id: String

    /// Tokenised card reference issued by the TSP.
    let tokenId: String

    /// Device PAN — the tokenised account number.
    let dpan: String

    /// Last four digits of the original PAN, for display only.
    let last4: String

    /// Brand: "mir", "visa", "mastercard", "amex".
    let scheme: String

    /// Expiry as "MM/YY".
    let expiry: String

    /// When the card was added to the wallet.
    let addedAt: Date

    init(tokenId: String,
         dpan: String,
         last4: String,
         scheme: String,
         expiry: String,
         addedAt: Date = Date()) {
        self.id = tokenId
        self.tokenId = tokenId
        self.dpan = dpan
        self.last4 = last4
        self.scheme = scheme
        self.expiry = expiry
        self.addedAt = addedAt
    }

    /// Brand name in Russian.
    var brandName: String {
        switch scheme.lowercased() {
        case "mir": return "Мир"
        case "visa": return "Visa"
        case "mastercard": return "Mastercard"
        case "amex": return "American Express"
        default: return scheme.capitalized
        }
    }

    /// Masked number for display: "•••• 1111".
    var maskedNumber: String {
        "•••• \(last4)"
    }
}

// MARK: - Store

/// Persistent wallet of saved cards.
///
/// The file is a JSON array in the app's Application Support directory. It
/// holds no secrets: the session key for each card lives in the Keychain,
/// keyed by the token id.
final class WalletStore {

    /// Where the wallet file lives by default.
    static func defaultFileURL() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil,
                                                 create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("wallet.json", isDirectory: false)
    }

    private let fileURL: URL
    private var _cards: [WalletCard] = []
    private var _primaryID: String?

    init(fileURL: URL = WalletStore.defaultFileURL()) {
        self.fileURL = fileURL
        load()
    }

    /// Saved cards, newest first.
    var cards: [WalletCard] { _cards }

    /// The card used for payments unless the user picks another one.
    var primaryCard: WalletCard? {
        if let _primaryID, let card = _cards.first(where: { $0.id == _primaryID }) {
            return card
        }
        return _cards.first
    }

    /// Adds a card, or refreshes it if it is already in the wallet.
    func add(_ card: WalletCard) {
        if let index = _cards.firstIndex(where: { $0.id == card.id }) {
            _cards[index] = card
        } else {
            _cards.append(card)
        }
        if _primaryID == nil {
            _primaryID = card.id
        }
        save()
    }

    /// Makes a card the primary one. Unknown ids are ignored.
    func setPrimary(id: String) {
        guard _cards.contains(where: { $0.id == id }) else { return }
        _primaryID = id
        save()
    }

    /// Removes a card. If it was primary, another card takes over.
    func remove(id: String) {
        _cards.removeAll { $0.id == id }
        if _primaryID == id {
            _primaryID = _cards.first?.id
        }
        save()
    }

    /// Removes every card.
    func removeAll() {
        _cards.removeAll()
        _primaryID = nil
        save()
    }

    // MARK: - Persistence

    private struct Payload: Codable {
        var cards: [WalletCard]
        var primaryID: String?
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return }
        _cards = payload.cards
        _primaryID = payload.primaryID
    }

    private func save() {
        let payload = Payload(cards: _cards, primaryID: _primaryID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
