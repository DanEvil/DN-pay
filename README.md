# DN pay

Исследовательский проект: воспроизведение полного протокола токенизации и
безконтактной оплаты карты «Мир» на iPhone — **протокольный стенд**, а не
работающий платёжный инструмент.

Ниже — честный разбор того, что сделано, что проверено, и что технически
невозможно при текущих ограничениях iOS.

---

## Что внутри

```
MirHCE/
├── server/
│   ├── mock_tsp.py          # Mock TSP + эмитент: 4 маршрута, выдача токена,
│   │                        # проверка криптограммы, анти-replay по ATC
│   └── test_mock_tsp.py     # 16 тестов, все зелёные
├── ios/
│   ├── project.yml          # XcodeGen-спека (генерирует .xcodeproj)
│   ├── MirWallet/
│   │   ├── App/MirWalletApp.swift
│   │   ├── Services/
│   │   │   ├── EmvCrypto.swift          # HKDF-SHA256 + ARQC
│   │   │   ├── TspClient.swift          # клиент TSP (Required Fields /
│   │   │   │                            # Check Card / Link and Provision)
│   │   │   ├── PaymentCoordinator.swift # полный цикл транзакции + тесты
│   │   │   ├── CardSessionController.swift  # HCE через CoreNFC
│   │   │   └── KeychainStore.swift      # хранение ключей в Keychain
│   │   ├── Views/RootView.swift         # UI: Оплата / TSP / NFC / Журнал
│   │   └── Resources/
│   │       ├── Info.plist
│   │       └── MirWallet.entitlements
│   └── MirWalletTests/      # 7 unit-тестов, включая вектор RFC 5869
├── tools/
│   ├── run_tsp.py           # запуск mock TSP
│   ├── install-sideloadly.sh
│   └── install-altstore.sh
└── .github/workflows/
    ├── build-ipa.yml        # сборка .ipa на macOS-раннере
    └── ci.yml               # тесты сервера + валидация plist/yaml
```

## Быстрый старт

### 1. Поднять mock TSP

```bash
python3 server/mock_tsp.py
# Mock TSP [MOCK-MIR-1] listening on http://0.0.0.0:8787
#   reachable from iPhone at: http://192.168.x.x:8787
```

Проверка:

```bash
python3 server/test_mock_tsp.py
# 16 passed, 0 failed
```

### 2. Собрать IPA

Actions → **Build IPA** → дождаться артефакта `MirWallet-ipa`.

Или локально на macOS:

```bash
cd ios
xcodegen generate
xcodebuild archive -project MirWallet.xcodeproj -scheme MirWallet \
  -configuration Release -destination "generic/platform=iOS" \
  -archivePath build/MirWallet.xcarchive CODE_SIGNING_ALLOWED=NO
```

### 3. Установить на iPhone

Подпись: **бесплатный Apple ID** (7 дней) или **платный** (1 год).

**Sideloadly** (Windows/macOS):
```bash
bash tools/install-sideloadly.sh MirWallet.ipa
```
Перетащите IPA в окно, выберите устройство, введите Apple ID, нажмите Start.

**AltStore** (Windows/macOS):
```bash
bash tools/install-altstore.sh MirWallet.ipa
```
Либо вручную: Shift + клик по иконке AltServer в трее → «Sideload .ipa…».

Требования на Windows: **iTunes 64-bit с сайта Apple** (не Microsoft Store),
iPhone разблокирован, включён Developer Mode.

### 4. Проверить на устройстве

В приложении: вкладка **TSP** → вписать адрес `http://<IP-компьютера>:8787` →
**Оплата** → «Выполнить транзакцию».

Ожидаемый результат: `Оплата одобрена`, ATC=1, ARQC показан в журнале.

Затем проверьте защиту: **Replay-тест** должен дать `Replay отклонён: atc_replay`,
**Тест подмены суммы** — `Подмена отклонена: cryptogram_mismatch`.

## Требования к устройству

| Параметр | Значение |
|---|---|
| Устройство | iPhone 13 mini и новее |
| iOS | 17.4+ (для `CardSession`); проверено на iOS 27.2 |
| Архитектура | arm64 |
| Build target | iOS 17.4 |
| Сеть | локальная (iPhone ↔ компьютер с mock TSP) |

Приложение **работает** на iPhone 13 mini / iOS 27.2: транзакционный контур
не зависит от версии iOS — это обычный HTTP + CryptoKit.

## Что невозможно и почему

### 1. Настоящий Apple Pay с картой «Мир» — невозможно

Якорь доверия — не серверы Apple, а эмитент/TSP. По Security Target Apple:

> «The cryptogram released by the Secure Element for an Apple Pay transaction is
> verified by the card issuer (or its service provider). […] The payment is
> invalidated if this verification fails.»

Ключ, которым Secure Element считает ARQC, провижинится **TSP эмитента** и
никогда не покидает чип. С 24 марта 2022 года Apple приостановила поддержку
карт «Мир» — российских эмитентов нет в онбординге Apple. Это серверная
проверка; локальный подменой Apple её не обойти.

### 2. `CardSession` (HCE) — закрыт Apple вне ЕЭЗ

Требуется:
- энтитлмент `com.apple.developer.nfc.hce` — Apple выдаёт только организациям
  из ЕЭЗ с лицензией на платёжные услуги;
- `CardSession.isEligible == true` — нужен Apple ID из ЕЭЗ **и** физическое
  нахождение в ЕЭЗ. Apple: «Using a VPN or other location spoofing techniques
  will not work. This is a hard requirement.»

**Sideloadly и AltStore энтитлмент не дают** — бесплатный provisioning profile
его просто не содержит. Включать его в `MirWallet.entitlements` нельзя: сборка
упадёт с `0xE8008016`, либо приложение умрёт на `CardSession.init()`.

Поэтому в `MirWallet.entitlements` этот ключ намеренно отсутствует, а
`CardSessionController` в рантайме определяет и показывает **какой именно
барьер блокирует** (нет энтитлмента / не выполнены условия ЕЭЗ / нет NFC /
симулятор).

### 3. Файловая подмена данных карты — только косметика

`/private/var/mobile/Library/Passes/Cards/*.pkpass` содержит `last4`, имя,
бренд, картинку — **не PAN и не ключи**. Реальные креды лежат в Secure Element.
Это ровно как в CarrierSIM: симлинк меняет, какой профиль подхватит телефон,
но криптографию SIM-карты (Ki) подменить нельзя.

### 4. «Сервер-имитация Apple» — не решает задачу

Проверку криптограммы делает эмитент. Локальный сервер, отвечающий за Apple,
не влияет на то, примет ли НСПК/эмитент транзакцию. Империровать TSP НСПК
требует её серверных mTLS-учёток — это серверные секреты, а не локальная правка.

## Почему проект всё равно полезен

Протокольный стенд даёт рабочую, проверяемую базу для:

- **разработки HCE-клиента** — когда Apple откроет доступ или появится
  партнёрский энтитлмент, код `CardSessionController` уже готов;
- **исследования EMV** — SELECT по AID, GPO, APDU-обмен, обработка
  `readerDetected` / `readerDeselected` / `sessionInvalidated`;
- **тестирования офлайн-режима** — ключи выдаются заранее и живут
  `--key-ttl` секунд, по истечении сервер требует переподключения;
- **проверки защиты транзакции** — anti-replay по ATC и привязка к сумме
  реализованы и покрыты тестами.

Криптография здесь — **мок-режим** (HKDF-SHA256 + HMAC-SHA256), согласованный
между Swift и Python. Это не схема «Мир» и не схема Apple. Токен, выпущенный
mock TSP, принимает только mock TSP.

## AID карт «Мир»

| Продукт | RID | AID |
|---|---|---|
| Мир Credit | `A000000658` | `A0000006581010` |
| Мир Debit | `A000000658` | `A0000006582010` |

Оба прописаны в `CardSessionController` и выбираются в приложении.

## Реальные способы оплаты в РФ на iPhone сегодня

| Способ | Транспорт | Работает офлайн |
|---|---|---|
| **Вжух** (Сбер) | Bluetooth LE | да |
| **T-Pay** (Т‑Банк) | Bluetooth LE | да (после первой онлайн-оплаты) |
| **«Волна»** (НСПК, ВТБ/Газпромбанк/ПСБ) | Bluetooth LE | да |
| **Mir Pay / «Яндекс Пэй»** на часах Huawei Watch 5 / 6 / Ultimate 2 | NFC | да |
| СБПэй, универсальный QR | QR | нет |
| Apple Pay с картой «Мир» | NFC | — (закрыто с 2022) |

Если цель — именно NFC + оффлайн + своя карта «Мир» без стикера, на сегодня
работают **часы Huawei** (собственный NFC-модуль, ключи в зашифрованном
хранилище, Mir Pay и «Яндекс Пэй»).

## Лицензия

MIT. См. `LICENSE`.
