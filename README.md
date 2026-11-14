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
│   │   │   ├── MockTspCore.swift       # mock TSP на Swift, маршрут в маршрут
│   │   │   ├── LocalTspServer.swift    # HTTP-сервер на 127.0.0.1 (Network.framework)
│   │   │   ├── NfcCapabilities.swift   # NFC: железо vs права, диагностика
│   │   │   └── KeychainStore.swift      # хранение ключей в Keychain
│   │   ├── Views/RootView.swift         # UI: Оплата / NFC / Журнал
│   │   └── Resources/
│   │       ├── Info.plist
│   │       └── MirWallet.entitlements
│   └── MirWalletTests/      # 9 unit-тестов, включая вектор RFC 5869
├── tools/
│   ├── run_tsp.py           # запуск mock TSP
│   ├── install-sideloadly.sh
│   └── install-altstore.sh
└── .github/workflows/
    ├── build-ipa.yml        # сборка .ipa на macOS-раннере
    └── ci.yml               # тесты сервера + валидация plist/yaml
```

## Быстрый старт

### 1. Mock TSP — уже работает

Сервер поднимается **внутри приложения** на `127.0.0.1:8787`
(`MockTspCore` + `LocalTspServer`, Network.framework) при запуске. Никакой
настройки не требуется: компьютер, Wi-Fi и сеть не нужны. Слушатель привязан
к loopback, поэтому из локальной сети он недоступен.

Отдельного таба с настройками нет — конфигурировать нечего.

Python на iOS заменой не является: a-Shell и iSH усыпляются, как только вы
переключаетесь на другое приложение, — сервер умирает ровно тогда, когда он
нужен.

Чтобы всё-таки направить клиент на Python-сервер в сети, задайте
UserDefaults-ключ `tsp.baseURL` (например `http://192.168.31.198:8787`).
Проверка Python-сервера:

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

Ничего настраивать не нужно: сервер уже поднят на `127.0.0.1:8787`.

**Оплата** → «Выполнить транзакцию».

Ожидаемый результат: `Оплата одобрена`, ATC=1, ARQC показан в журнале.

Затем проверьте защиту: **Replay-тест** должен дать `Replay отклонён: atc_replay`,
**Тест подмены суммы** — `Подмена отклонена: cryptogram_mismatch`.

## Автономность: почему сервер внутри приложения

Раньше mock TSP жил на ноутбуке, а телефон ходил к нему по Wi-Fi. Это работало
только рядом с компьютером — в магазине или в дороге приложение становилось
бесполезным.

Запустить Python прямо на iPhone нельзя:

| Вариант | Почему не подходит |
|---|---|
| a-Shell (App Store) | iOS усыпляет приложение при переключении на другое — сервер умирает |
| iSH (App Store) | то же, плюс эмуляция x86 тормозит |
| Pythonista | только для macOS/iOS, но это платная IDE, не сервер |
| Фоновый режим iOS | приложение не может висеть в фоне с открытым сокетом |

Поэтому сервер перенесён внутрь приложения: `MockTspCore` повторяет
`server/mock_tsp.py` маршрут в маршрут и байт в байт, а `LocalTspServer`
отдаёт его по HTTP на loopback через Network.framework.

Что это даёт:

- телефон работает **автономно** — никакого компьютера и сети;
- **тот же клиент** и тот же протокол, что и с внешним сервером;
- сервер **недоступен из сети** — listener привязан к `127.0.0.1`;
- master-ключ лежит в Keychain, поэтому токены переживают перезапуск;
- CI проверяет обе реализации: `tools/parity_check.py` сверяет Swift и Python,
  а unit-тесты покрывают встроенное ядро.

## Требования к устройству

| Параметр | Значение |
|---|---|
| Устройство | iPhone 13 mini и новее |
| iOS | 17.4+ (для `CardSession`); проверено на iOS 27.2 |
| Архитектура | arm64 |
| Build target | iOS 17.4 |
| Сеть | не требуется (встроенный TSP); локальная — только для внешнего режима |

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

Поэтому в `MirWallet.entitlements` этот ключ намеренно отсутствует.

#### Как приложение отличает «нет NFC» от «нет прав»

Раньше приложение проверяло `NFCReaderSession.readingAvailable` и
`CardSession.isSupported` и при `false` писало «устройство не поддерживает
NFC». Это **неверный вывод**: оба флага возвращают `false` и когда NFC в
телефоне есть, но у приложения нет энтитлмента — а бесплатный Apple ID
профиль его не содержит никогда.

Теперь (`NfcCapabilities.swift`) вопросы разделены:

| Вопрос | Источник ответа |
|---|---|
| Есть ли NFC-модуль? | идентификатор модели (`iPhone14,4` и т.п.). iPhone XS и новее — есть |
| Есть ли права на HCE? | энтитлменты из встроенного provisioning profile |
| Разрешена ли эмуляция сейчас? | `CardSession.isEligible` |

Таб **NFC** показывает сырые значения — модель, `readingAvailable`,
`isSupported`, `isEligible`, наличие профиля и его энтитлменты, — чтобы
вердикт можно было проверить, а не принять на веру.

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

## Разбор SDK Яндекс.Кассы (yandex-checkout-payments-swift)

Репозиторий [`artemnovichkov/yandex-checkout-payments-swift`](https://github.com/artemnovichkov/yandex-checkout-payments-swift)
(форк `yandex-money`, upstream переехал в `yoomoney/yookassa-payments-swift`)
изучен построчно: `ApplePayServiceImpl`, `ApplePayContractInteractor`,
`ApplePayContractPresenter`, `TokenizationModuleInputData`, `CardService`,
`Tokens`, `PaymentServiceImpl`.

**Что это за SDK.** Мобильный SDK для **приёма** платежей в вашем приложении
(эквайринг), дополнение к API Яндекс.Кассы. Он выпускает `payment_token`,
который вы отправляете на свой бэкенд и создаёте платёж через API.

**Почему он не решает задачу «платить своей картой в магазине РФ».**

| | SDK ЮKassa | Задача |
|---|---|---|
| Сторона | продавец (эквайринг) | плательщик (NFC-оплата) |
| Роль | выпускает токен для приёма платежа | эмитует криптограмму для терминала |
| Транспорт | HTTP к API ЮKassa | NFC (ISO 7816 / EMV) |
| Apple Pay в нём | `PKPaymentAuthorizationController` → токен продавцу | `CardSession` → APDU терминалу |
| Ключи | серверные, у продавца | в Secure Element телефона |

Конкретно по Apple Pay в SDK:

- `ApplePayServiceImpl` строит `PKPaymentRequest`, настраивает
  `merchantIdentifier` / `countryCode` / `currencyCode` / `supportedNetworks`,
  вызывает `PKPaymentAuthorizationController.present`;
- `ApplePayContractInteractor` шифрует `paymentData` сертификатом продавца
  (тот самый `.csr`-обмен с Apple, который описан в инструкции Яндекс.Кассы);
- `ApplePayContractPresenter` по завершении отдаёт `Tokens`
  (`paymentToken` + `type`) — их и надо передать в `payment_token` при создании
  платежа;
- сеть `mir` в `PKPaymentNetwork` доступна с **iOS 14.5+**, но это сеть
  **эквайера**: терминал в РФ должен быть настроен на приём Apple Pay от
  этого продавца, а не «любая карта «Мир» в телефоне».

Полезное из SDK для нашего стенда:

- **Test mode** (`TestModeSettings`) — ровно тот же приём, что делает наш
  `mock_tsp.py`: сервер не вызывается, ответ имитируется;
- **3-D Secure** (`start3dsProcess(requestUrl:)`) — схема «клиент держит модуль
  открытым, пока сервер не подтвердит»;
- ** сканирование карт** (`CardScannerProvider` / CardIO) — отдельный SDK.

Но **`TokenizationModuleInputData` требует ключ для клиентских приложений** из
кабинета Яндекс.Кассы и `TrustDefender.framework`, который выдаёт менеджер
ЮKassa. Без подключённого магазина это не запускается.

**Вывод:** это эталон merchant-side реализации Apple Pay. Как образец —
прекрасный (структура модулей, обработка ошибок, test mode, логирование).
Как решение задачи «платить в магазинах РФ своей картой «Мир» через NFC» —
нет: у SDK нет ни HCE, ни `CardSession`, ни эмитентской стороны.

## iPhone 13 mini и iOS 27.2

Целевая конфигурация заявлена как iPhone 13 mini / iOS 27.2 — приложение
собрано под `MinimumOSVersion 17.4` и `arm64`, поэтому ставится и работает на
любом iPhone XS+ с iOS 17.4 и выше, включая 13 mini.

Что стоит знать:

- **Сборка** идёт на iOS SDK 26.2 / Xcode 26.3, `MinimumOSVersion = 17.4`,
  `UIRequiredDeviceCapabilities = [arm64]` — совместимо с 13 mini;
- **Транзакционный контур** (TSP + криптограмма) — обычный HTTP + CryptoKit,
  версия iOS ни на что не влияет, работает офлайн по локальной сети;
- **HCE-путь** (`CardSession`) требует iOS 17.4+ и, помимо версии, —
  энтитлмента Apple, которого вне ЕЭЗ не существует (см. раздел выше);
- **Apple ID** для установки: бесплатный — 7 дней с переподписью, платный — 1 год;
- устройство должно быть в **Developer Mode** (Настройки → Конфиденциальность →
  Режим разработчика).

## Установка подписанного IPA

Артефакт `MirWallet-signed.ipa` — ad-hoc подписанный (zsign). Он подходит для:

- **Sideloadly** — Sideloadly всё равно переподписывает своим сертификатом;
- **AltStore** — то же;
- **TrollStore** — ставит как есть, подпись не проверяется.

Обычная установка `.ipa` через `ideviceinstaller` требует Apple-подписанного
сертификата: zsign не смог собрать цепочку WWDR, потому что у нас нет
сертификата, выданного Apple. Собственный сертификат без промежуточного
WWDR-сертификата Apple iOS не принимает — это ограничение платформы, а не
инструмента.

## Сборка и CI

| Workflow | Что делает | Статус |
|---|---|---|
| `ci.yml` | тесты mock TSP (16), cross-language parity Swift↔Python, валидация plist/YAML | зелёный |
| `build-ipa.yml` | XcodeGen → xcodebuild archive → export → unit-тесты → артефакт `MirWallet-ipa` | зелёный |

Артефакт IPA (~98 КБ) лежит в каждом успешном ране **Build IPA**:
`Actions → Build IPA → Artifacts → MirWallet-ipa`.

Подписанный IPA собирается автоматически, если задать secrets
`CERT_P12_BASE64` и `PROVISIONING_PROFILE_BASE64`; без них собирается
unsigned-вариант, который Sideloadly/AltStore переподписывают локально.

Раннер — `macos-15` с авто-выбором установленного Xcode (`macos-14` сейчас
arm64-only и не принимает x86_64 job-метку).

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
