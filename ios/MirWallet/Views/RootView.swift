//
//  RootView.swift
//  MirWallet
//
//  Tab-based UI: TSP connection, payment flow, HCE status, diagnostics.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var payment: PaymentCoordinator
    @EnvironmentObject private var hce: CardSessionController

    var body: some View {
        TabView {
            PaymentView()
                .tabItem { Label("Оплата", systemImage: "creditcard") }

            HceView()
                .tabItem { Label("NFC", systemImage: "wave.3.right") }

            LogView()
                .tabItem { Label("Журнал", systemImage: "doc.text.magnifyingglass") }
        }
    }
}

// MARK: - Payment

struct PaymentView: View {
    @EnvironmentObject private var payment: PaymentCoordinator

    var body: some View {
        NavigationStack {
            Form {
                Section("Карта") {
                    TextField("Номер карты", text: $payment.pan)
                        .keyboardType(.numberPad)
                        .textContentType(.creditCardNumber)
                    TextField("Срок (ММ/ГГ)", text: $payment.expiry)
                    SecureField("CVV", text: $payment.cvv)
                        .keyboardType(.numberPad)
                    Text("Тестовая карта 2200123456789019 — mock TSP, никаких реальных списаний.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Сумма") {
                    TextField("Копейки", text: $payment.amountMinor)
                        .keyboardType(.numberPad)
                    TextField("Валюта", text: $payment.currency)
                    if let amount = Int(payment.amountMinor) {
                        Text("Итого: \(String(format: "%.2f", Double(amount) / 100)) \(payment.currency)")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        Task { await payment.runTransaction() }
                    } label: {
                        HStack {
                            Text("Выполнить транзакцию")
                            Spacer()
                            if payment.isBusy { ProgressView() }
                        }
                    }
                    .disabled(payment.isBusy)

                    Button("Replay-тест (тот же ATC)") {
                        Task { await payment.runReplayAttack() }
                    }
                    Button("Тест подмены суммы") {
                        Task { await payment.runTamperTest() }
                    }
                    .foregroundStyle(.orange)
                }

                Section("Состояние") {
                    LabeledContent("Статус", value: payment.stage.title)
                    LabeledContent("Токен", value: payment.tokenId ?? "—")
                    LabeledContent("DPAN", value: payment.dpan ?? "—")
                    LabeledContent("Последние 4", value: payment.last4.map { "••••\($0)" } ?? "—")
                    LabeledContent("ATC", value: String(payment.atc))
                    LabeledContent("Ключи", value: payment.keysRemainingDescription)
                }

                Section {
                    Button("Очистить сессию", role: .destructive) {
                        payment.clearSession()
                    }
                }
            }
            .navigationTitle("DN pay")
        }
    }
}

// MARK: - HCE

// MARK: - HCE

struct HceView: View {
    @EnvironmentObject private var hce: CardSessionController

    var body: some View {
        NavigationStack {
            Form {
                Section("Статус HCE") {
                    LabeledContent("Режим", value: hce.gate.title)
                    Text(hce.gate.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Диагностика") {
                    LabeledContent("Модель", value: hce.capabilities.model.isEmpty ? "—" : hce.capabilities.model)
                    LabeledContent("NFC-модуль", value: hce.capabilities.hardware.title)
                    LabeledContent("readingAvailable", value: hce.capabilities.readingAvailable.map { $0 ? "true" : "false" } ?? "—")
                    LabeledContent("CardSession.isSupported", value: hce.capabilities.cardSessionSupported.map { $0 ? "true" : "false" } ?? "—")
                    LabeledContent("CardSession.isEligible", value: hce.capabilities.cardSessionEligible.map { $0 ? "true" : "false" } ?? "—")
                    LabeledContent("Профиль подписи", value: hce.capabilities.profileFound ? "найден" : "не найден")
                    LabeledContent("Энтитлмент HCE", value: hce.capabilities.hasHCE ? "есть" : "нет")
                }

                if !hce.capabilities.entitlementKeys.isEmpty {
                    Section("Энтитлменты профиля") {
                        ForEach(hce.capabilities.entitlementKeys, id: \.self) { key in
                            Text(key)
                                .font(.caption.monospaced())
                        }
                    }
                }

                Section {
                    Button("Запустить эмуляцию") {
                        Task {
                            await hce.startEmulation(aids: [
                                CardSessionController.mirCreditAID,
                                CardSessionController.mirDebitAID,
                            ])
                        }
                    }
                    .disabled(hce.isEmulating)

                    Button("Остановить") { hce.stopEmulation() }
                        .disabled(!hce.isEmulating)
                }

                Section("AID") {
                    Text("Mir Credit: \(CardSessionController.mirCreditAID)").font(.footnote.monospaced())
                    Text("Mir Debit:  \(CardSessionController.mirDebitAID)").font(.footnote.monospaced())
                }

                Section("Журнал NFC") {
                    if hce.log.isEmpty {
                        Text("Событий нет").foregroundStyle(.secondary)
                    } else {
                        ForEach(hce.log.suffix(40), id: \.self) { line in
                            Text(line).font(.caption.monospaced())
                        }
                    }
                }
            }
            .navigationTitle("NFC")
            .task {
                await hce.evaluateGate()
            }
        }
    }
}

// MARK: - Log

struct LogView: View {
    @EnvironmentObject private var payment: PaymentCoordinator

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if payment.journal.isEmpty {
                        Text("Журнал пуст").foregroundStyle(.secondary)
                    }
                    ForEach(Array(payment.journal.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle("Журнал")
        }
    }
}
