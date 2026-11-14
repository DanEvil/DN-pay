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

    init() {
        // Bring up the in-app TSP straight away so the first transaction works
        // without any setup.
        _ = TspClient.shared.startEmbeddedServer()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(payment)
                .environmentObject(hce)
        }
    }
}
