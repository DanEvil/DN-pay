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

            TspSettingsView()
                .tabItem { Label("TSP", systemImage: "server.rack") }

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

// MARK: - TSP settings

struct TspSettingsView: View {
    @EnvironmentObject private var payment: PaymentCoordinator
    @State private var urlText: String = ""
    @State private var health: String = "—"

    private var tsp: TspClient { TspClient.shared }

    var body: some View {
        NavigationStack {
            Form {
                Section("Режим TSP") {
                    Picker("Источник", selection: Binding(
                        get: { tsp.mode },
                        set: { tsp.setMode($0) }
                    )) {
                        ForEach(TspClient.Mode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(tsp.mode.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if tsp.mode == .external {
                    Section("Адрес TSP") {
                        TextField("http://192.168.x.x:8787", text: $urlText)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Сохранить") {
                            tsp.updateBaseURL(urlText)
                            health = "…"
                        }
                    }
                }

                Section {
                    Button("Проверить") {
                        Task { await checkHealth() }
                    }
                }

                Section {
                    Text(health)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                    if let error = tsp.embeddedError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Состояние")
                } footer: {
                    Text(tsp.mode == .embedded
                         ? "Встроенный TSP поднят на 127.0.0.1 — доступен только с самого телефона."
                         : "Локальный mock TSP запускается командой: python3 server/mock_tsp.py")
                }
            }
            .navigationTitle("TSP")
            .onAppear {
                urlText = tsp.baseURL.absoluteString
                if tsp.mode == .embedded {
                    _ = tsp.startEmbeddedServer()
                }
            }
        }
    }

    private func checkHealth() async {
        let url: URL
        if tsp.mode == .embedded {
            _ = tsp.startEmbeddedServer()
            url = tsp.embeddedServer?.baseURL ?? URL(string: "http://127.0.0.1:8787")!
        } else {
            guard let parsed = URL(string: urlText) else {
                health = "неверный URL"
                return
            }
            url = parsed
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url.appendingPathComponent("/tsp/health"))
            health = String(data: data, encoding: .utf8) ?? "—"
        } catch {
            health = "недоступен: \(error.localizedDescription)"
        }
    }
}

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
