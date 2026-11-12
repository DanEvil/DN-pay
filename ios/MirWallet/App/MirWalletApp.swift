//
//  MirWalletApp.swift
//  MirWallet
//
//  App entry point.
//

import SwiftUI

@main
struct MirWalletApp: App {
    @StateObject private var payment = PaymentCoordinator()
    @StateObject private var hce = CardSessionController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(payment)
                .environmentObject(hce)
        }
    }
}
