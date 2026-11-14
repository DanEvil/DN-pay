//
//  MockTerminal.swift
//  MirWallet
//
//  The point-of-sale terminal, simulated.
//
//  In a real payment the amount belongs to the terminal, not to the phone:
//  the customer taps, the terminal says how much, and the phone signs that
//  exact figure. This type models that side so the app can be exercised
//  without a card reader.
//
//  When a real terminal is present (HCE path), the amount arrives in the
//  EMV tags instead — see CardSessionController.
//

import Foundation

// MARK: - Request

/// A transaction request as the terminal presents it.
struct TerminalRequest: Equatable {

    /// Amount in minor units (kopecks for RUB).
    let amountMinor: String

    /// Currency code.
    let currency: String

    /// Unpredictable number, fresh per transaction.
    let unpredictableNumber: Data

    /// Terminal verification results.
    let tvr: String

    /// Transaction type: "00" for a purchase.
    let transactionType: String

    /// Human-readable amount, e.g. "19.90".
    var amountDisplay: String {
        guard let value = Int(amountMinor) else { return amountMinor }
        return String(format: "%.2f", Double(value) / 100)
    }

    /// Amount with the currency, e.g. "19.90 RUB".
    var amountWithCurrency: String {
        "\(amountDisplay) \(currency)"
    }
}

// MARK: - Terminal

/// Simulated point-of-sale terminal.
struct MockTerminal {

    /// Amounts the terminal cycles through, in minor units.
    var amounts: [String]

    /// Currency the terminal charges in.
    var currency: String

    private var index = 0

    init(amounts: [String] = ["1990", "4990", "100"], currency: String = "RUB") {
        self.amounts = amounts.isEmpty ? ["1990"] : amounts
        self.currency = currency
    }

    /// Produces the next transaction request.
    mutating func nextRequest() -> TerminalRequest {
        let amount = amounts[index % amounts.count]
        index += 1
        return TerminalRequest(
            amountMinor: amount,
            currency: currency,
            unpredictableNumber: EmvCrypto.randomBytes(count: 8),
            tvr: "0000000000",
            transactionType: "00"
        )
    }
}
