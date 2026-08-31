# FreeDV Reporter 整合 — 開發規劃

> 目標：在 iOS App 中加入即時 FreeDV Reporter 回報功能。使用者設定呼號、Grid Square、頻率後，App 在接收到 RADE 訊號時自動向 `qso.freedv.org` 回報。

---

## 1. FreeDV Reporter 協議摘要

### 1.1 傳輸層

FreeDV Reporter 使用 **Socket.IO v4**（底層是 Engine.IO over WebSocket）與伺服器通訊。

- **伺服器：** `qso.freedv.org`，port 80
- **協議版本：** 2（在 auth payload 中的 `protocol_version` 欄位）
- **資料格式：** JSON

Socket.IO 的訊息格式是在 WebSocket frame 前加上類型碼：
- `0` = Engine.IO open
- `2` = Engine.IO ping
- `3` = Engine.IO pong
- `40` = Socket.IO connect（後接 auth JSON）
- `42` = Socket.IO event（後接 `["event_name", {data}]` JSON 陣列）

### 1.2 連線認證

連線時 client 發送 auth payload：

**RX-only SWL 模式（我們的 App 使用這個）：**
```json
40{
  "role": "report",
  "callsign": "BV2xxx",
  "grid_square": "PL04qf",
  "version": "FreeDV iOS 1.0",
  "rx_only": true,
  "os": "iOS 17.0",
  "protocol_version": 2
}
```

**view-only 模式（不上報，只看別人）：**
```json
40{
  "role": "view",
  "protocol_version": 2
}
```

`rx_only: true` 表示僅接收，不能發射。伺服器會在 Reporter 表格中顯示為 "RX Only"。

### 1.3 Client → Server 事件

我們的 SWL App 需要發送以下事件：

#### `freq_change` — 使用者切換頻率
```json
["freq_change", {"freq": 14236000}]
```
頻率單位是 **Hz**（整數）。使用者在 App 中改變接收頻率時發送。

#### `rx_report` — 收到訊號回報（核心功能）
```json
["rx_report", {
  "callsign": "VK5DGR",
  "mode": "RADEV1",
  "snr": 12
}]
```
當 RADE 解碼器成功解出一個呼號（EOO callsign）時發送。只有在收到伺服器的 `connection_successful` 後才能開始發送。

**注意：** RADE V1 目前的 callsign 傳輸依賴 EOO（End-of-over）frame，也就是在對方停止發射時才解碼出呼號。所以帶呼號的 `rx_report` 是在 EOO 偵測到時發送的。

**週期回報（2026-09-01 實測修正）：** 桌面版 freedv-gui 在 RADE 同步期間會以**每 ~0.5–1 秒**一次的頻率持續送出「空呼號」的 `rx_report`（`{"callsign": "", "mode": "RADEV1", "snr": N}`；來源：main.cpp 100 ms timer × `m_reportCounter % 10`；對 qso.freedv.org 實測 FreeDV 2.3.1 電台 median 0.50 s、n=434）。網站每收到一筆就重啟該列 20 秒的藍色 highlight 淡出動畫（index.js `rxReportFn`，先 `stop(true,true)` 跳到底色再重新上色）。**回報週期若明顯大於數秒，該電台的列就會在兩次回報之間肉眼可見地褪回「未接收」底色** — v1.2 曾誤把桌面版節奏讀成 10 秒導致此問題（日本用戶回報 13 s/3 s 週期變色）。iOS 端現行作法：同步期間每 1 秒送空呼號報告，EOO 解碼時立即補一筆帶呼號的報告。

#### `message_update` — 狀態訊息
```json
["message_update", {"message": "SWL in Taichung"}]
```
可選功能，讓使用者設定自訂狀態訊息。

### 1.4 Server → Client 事件

如果 App 想顯示其他電台的活動（非必須但加分）：

| 事件 | 說明 |
|------|------|
| `connection_successful` | 伺服器握手完成，此後才能發送 `rx_report` |
| `bulk_update` | 連線時一次送來所有目前在線電台的狀態 |
| `new_connection` | 有電台加入 |
| `remove_connection` | 有電台離開 |
| `freq_change` | 其他電台換頻 |
| `tx_report` | 其他電台開始/停止發射 |
| `rx_report` | 其他電台收到訊號 |
| `message_update` | 其他電台更新訊息 |

每個事件 payload 都包含 `sid`（session ID）和 `last_update`（ISO 8601 **字串**）來識別電台。

**2026-09-01 實測補充：**
- Engine.IO 握手參數為 `pingInterval=5000, pingTimeout=5000`（非預設的 25 s/20 s）— 客戶端若 ~10 秒內沒回 PONG 就會被伺服器踢掉，斷線後 `sid` 會換新。
- 廣播的 `rx_report`／`freq_change` 等事件實際上**包在 `bulk_update` 裡送**（常見單筆的 `["bulk_update", [["rx_report", {...}]]]`），不只連線時才有 `bulk_update`。
- 換頻等原因清除 RX 資料時，伺服器會廣播 `mode` 與 `callsign` 皆為空字串的 `rx_report`（網站以此清空該列的 Last RX/SNR 欄）。

### 1.5 連線生命週期

```
App                                 qso.freedv.org
 |                                        |
 |-- WebSocket connect ------------------->|
 |<- Engine.IO open (sid, pingInterval) ---|
 |-- 40{auth payload} -------------------->|
 |<- 40{sid} (Socket.IO connect ack) -----|
 |<- 42["new_connection", {...}] ---------|  (自己的)
 |<- 42["bulk_update", [...]] ------------|  (所有在線電台)
 |<- 42["connection_successful", {}] -----|  ★ 此後才能發送 rx_report
 |                                        |
 |-- 42["freq_change", {...}] ------------>|  (使用者設定頻率)
 |-- 42["message_update", {...}] --------->|  (可選狀態訊息)
 |                                        |
 |  (解碼到 EOO 呼號時)                     |
 |-- 42["rx_report", {...}] -------------->|  ★ 核心功能
 |                                        |
 |  (定期心跳)                              |
 |-- 2 (Engine.IO ping) ----------------->|
 |<- 3 (Engine.IO pong) -----------------|
 |                                        |
 |  (App 進入背景或使用者停止)               |
 |-- WebSocket close --------------------->|
```

---

## 2. iOS 實作方案

### 2.1 Socket.IO 客戶端選擇

iOS 有幾個選項：

**選項 A：Socket.IO-Client-Swift（推薦）**
- GitHub: `socketio/socket.io-client-swift`
- SPM: `https://github.com/socketio/socket.io-client-swift.git`
- 原生 Swift，支援 Socket.IO v4
- 穩定，社群大

**選項 B：自己用 URLSessionWebSocketTask 實作**
- 不需要第三方依賴
- 但要自己處理 Engine.IO/Socket.IO 協議（ping/pong、重連、message framing）
- 較多工作量

**選項 C：Starscream + 手動 Socket.IO 解析**
- 用 Starscream 做 WebSocket，自己解析 Socket.IO frame
- Peter Marks 的 radae_decoder 就是這樣做的（IXWebSocket + 手動 Engine.IO 解析）

**推薦選項 A**，用 SPM 引入 Socket.IO-Client-Swift 最省事。

### 2.2 FreeDVReporter.swift

```swift
import SocketIO
import Foundation

class FreeDVReporter: ObservableObject {
    
    // MARK: - 設定（使用者填寫）
    @Published var callsign: String = ""          // 呼號，如 "BV2ABC"
    @Published var gridSquare: String = ""        // Maidenhead Grid，如 "PL04qf"
    @Published var frequencyHz: UInt64 = 14236000 // 接收頻率 Hz
    @Published var statusMessage: String = ""     // 自訂狀態訊息
    
    // MARK: - 連線狀態
    @Published var isConnected = false
    @Published var isReady = false  // connection_successful 後才 true
    
    // MARK: - 在線電台（可選：顯示其他電台）
    @Published var stations: [String: ReporterStation] = [:]  // sid → station
    
    // MARK: - 私有
    private var manager: SocketManager?
    private var socket: SocketIOClient?
    
    private let serverURL = URL(string: "http://qso.freedv.org")!
    private let protocolVersion = 2
    
    // MARK: - 連線
    
    func connect() {
        guard !callsign.isEmpty, !gridSquare.isEmpty else {
            // 沒有呼號就用 view-only 模式
            connectAsViewer()
            return
        }
        
        let authPayload: [String: Any] = [
            "role": "report",
            "callsign": callsign.uppercased(),
            "grid_square": gridSquare,
            "version": "FreeDV iOS \(Bundle.main.shortVersion)",
            "rx_only": true,
            "os": "iOS \(UIDevice.current.systemVersion)",
            "protocol_version": protocolVersion
        ]
        
        manager = SocketManager(
            socketURL: serverURL,
            config: [
                .log(false),
                .compress,
                .connectParams(authPayload),
                .forceWebsockets(true)
            ]
        )
        
        socket = manager?.defaultSocket
        setupEventHandlers()
        socket?.connect()
    }
    
    func disconnect() {
        socket?.disconnect()
        isConnected = false
        isReady = false
        stations.removeAll()
    }
    
    private func connectAsViewer() {
        let authPayload: [String: Any] = [
            "role": "view",
            "protocol_version": protocolVersion
        ]
        manager = SocketManager(
            socketURL: serverURL,
            config: [
                .connectParams(authPayload),
                .forceWebsockets(true)
            ]
        )
        socket = manager?.defaultSocket
        setupEventHandlers()
        socket?.connect()
    }
    
    // MARK: - 事件處理
    
    private func setupEventHandlers() {
        guard let socket else { return }
        
        socket.on(clientEvent: .connect) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.isConnected = true
            }
        }
        
        socket.on(clientEvent: .disconnect) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.isConnected = false
                self?.isReady = false
            }
        }
        
        // ★ 伺服器握手完成
        socket.on("connection_successful") { [weak self] _, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isReady = true
            }
            // 發送初始狀態
            self.sendFreqChange()
            self.sendMessageUpdate()
        }
        
        // 新電台連線
        socket.on("new_connection") { [weak self] data, _ in
            self?.handleNewConnection(data)
        }
        
        // 電台離線
        socket.on("remove_connection") { [weak self] data, _ in
            self?.handleRemoveConnection(data)
        }
        
        // 批量更新（初始連線時）
        socket.on("bulk_update") { [weak self] data, _ in
            self?.handleBulkUpdate(data)
        }
        
        // 其他電台的 rx_report（顯示誰在收誰）
        socket.on("rx_report") { [weak self] data, _ in
            self?.handleRxReport(data)
        }
        
        // 其他電台的 freq_change
        socket.on("freq_change") { [weak self] data, _ in
            self?.handleFreqChange(data)
        }
        
        // 其他電台的 tx_report
        socket.on("tx_report") { [weak self] data, _ in
            self?.handleTxReport(data)
        }
    }
    
    // MARK: - 發送事件（Client → Server）
    
    /// 使用者改變頻率時呼叫
    func sendFreqChange() {
        socket?.emit("freq_change", ["freq": frequencyHz])
    }
    
    /// ★ 核心：解碼到呼號時呼叫
    func reportRx(callsign: String, snr: Int) {
        guard isReady else { return }
        socket?.emit("rx_report", [
            "callsign": callsign,
            "mode": "RADEV1",
            "snr": snr
        ])
    }
    
    /// 更新狀態訊息
    func sendMessageUpdate() {
        socket?.emit("message_update", ["message": statusMessage])
    }
    
    // MARK: - Server 事件處理（可選，顯示其他電台）
    
    private func handleNewConnection(_ data: [Any]) {
        guard let dict = data.first as? [String: Any],
              let sid = dict["sid"] as? String,
              let callsign = dict["callsign"] as? String else { return }
        
        DispatchQueue.main.async {
            self.stations[sid] = ReporterStation(
                sid: sid,
                callsign: callsign.uppercased(),
                gridSquare: (dict["grid_square"] as? String) ?? "",
                version: (dict["version"] as? String) ?? "",
                rxOnly: (dict["rx_only"] as? Bool) ?? false,
                lastUpdate: Date()
            )
        }
    }
    
    private func handleRemoveConnection(_ data: [Any]) {
        guard let dict = data.first as? [String: Any],
              let sid = dict["sid"] as? String else { return }
        DispatchQueue.main.async {
            self.stations.removeValue(forKey: sid)
        }
    }
    
    private func handleBulkUpdate(_ data: [Any]) {
        guard let updates = data.first as? [[Any]] else { return }
        for update in updates {
            guard update.count == 2,
                  let eventName = update[0] as? String,
                  let eventData = update[1] as? [String: Any] else { continue }
            
            switch eventName {
            case "new_connection":
                handleNewConnection([eventData])
            case "freq_change":
                handleFreqChange([eventData])
            case "tx_report":
                handleTxReport([eventData])
            default:
                break
            }
        }
    }
    
    private func handleRxReport(_ data: [Any]) {
        guard let dict = data.first as? [String: Any],
              let sid = dict["sid"] as? String else { return }
        DispatchQueue.main.async {
            self.stations[sid]?.lastRxCallsign = dict["callsign"] as? String
            self.stations[sid]?.lastRxSNR = dict["snr"] as? Double
            self.stations[sid]?.lastUpdate = Date()
        }
    }
    
    private func handleFreqChange(_ data: [Any]) {
        guard let dict = data.first as? [String: Any],
              let sid = dict["sid"] as? String else { return }
        DispatchQueue.main.async {
            self.stations[sid]?.frequencyHz = dict["freq"] as? UInt64
            self.stations[sid]?.lastUpdate = Date()
        }
    }
    
    private func handleTxReport(_ data: [Any]) {
        guard let dict = data.first as? [String: Any],
              let sid = dict["sid"] as? String else { return }
        DispatchQueue.main.async {
            self.stations[sid]?.transmitting = (dict["transmitting"] as? Bool) ?? false
            self.stations[sid]?.mode = dict["mode"] as? String
            self.stations[sid]?.lastUpdate = Date()
        }
    }
}

// MARK: - 資料模型

struct ReporterStation: Identifiable {
    let sid: String
    var callsign: String
    var gridSquare: String
    var version: String
    var rxOnly: Bool
    var frequencyHz: UInt64?
    var mode: String?
    var transmitting: Bool = false
    var lastRxCallsign: String?
    var lastRxSNR: Double?
    var lastUpdate: Date
    var message: String?
    
    var id: String { sid }
}

// Bundle extension
extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
```

### 2.3 與現有音訊管線的整合

在 `AudioManager.swift` 中，EOO callsign 解碼時觸發 report：

```swift
// AudioManager.swift 中現有的 EOO 偵測邏輯

// 當 rade_rx() 回傳 hasEoo = true 時：
if hasEoo {
    let callsign = decodeEooCallsign(eooData)
    if let callsign = callsign, !callsign.isEmpty {
        // 通知 UI 顯示呼號
        DispatchQueue.main.async {
            self.decodedCallsign = callsign
        }
        
        // ★ 回報到 FreeDV Reporter
        let snr = Int(currentSNR)
        reporter?.reportRx(callsign: callsign, snr: snr)
    }
}
```

---

## 3. UI 設計

### 3.1 Reporter 設定頁面

在 SettingsView 中加入新的 section：

```swift
Section("FreeDV Reporter") {
    Toggle("啟用回報", isOn: $viewModel.reporterEnabled)
    
    if viewModel.reporterEnabled {
        // 呼號（必填）
        HStack {
            Text("呼號")
            TextField("如 BV2ABC", text: $viewModel.callsign)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
        }
        
        // Grid Square（必填）
        HStack {
            Text("Grid Square")
            TextField("如 PL04qf", text: $viewModel.gridSquare)
                .autocorrectionDisabled()
        }
        
        // 接收頻率（必填）
        HStack {
            Text("頻率 (kHz)")
            TextField("如 14236", value: $viewModel.frequencyKHz, format: .number)
                .keyboardType(.decimalPad)
        }
        
        // 狀態訊息（可選）
        HStack {
            Text("狀態訊息")
            TextField("如 SWL in Taichung", text: $viewModel.statusMessage)
        }
        
        // 連線狀態
        HStack {
            Text("狀態")
            Spacer()
            if viewModel.reporterConnected {
                Label("已連線", systemImage: "circle.fill")
                    .foregroundColor(.green)
            } else {
                Label("未連線", systemImage: "circle")
                    .foregroundColor(.gray)
            }
        }
    }
}
```

### 3.2 主畫面的 Reporter 指示

在 TransceiverView 的 StatusBar 加入 Reporter 連線指示：

```swift
// StatusBar 尾端
if viewModel.reporterEnabled {
    Image(systemName: viewModel.reporterConnected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
        .foregroundColor(viewModel.reporterConnected ? .green : .red)
        .font(.caption)
}
```

### 3.3 在線電台列表（可選加分功能）

新增一個 Tab 或 Sheet 顯示目前在線的 FreeDV 電台：

```swift
struct ReporterStationsView: View {
    @ObservedObject var reporter: FreeDVReporter
    
    var body: some View {
        List(sortedStations) { station in
            HStack {
                VStack(alignment: .leading) {
                    Text(station.callsign)
                        .font(.headline)
                    Text(station.gridSquare)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if let freq = station.frequencyHz {
                    Text(String(format: "%.3f MHz", Double(freq) / 1_000_000))
                        .font(.caption.monospacedDigit())
                }
                
                // 狀態圓點
                Circle()
                    .fill(stationColor(station))
                    .frame(width: 8, height: 8)
            }
        }
        .navigationTitle("在線電台")
    }
    
    var sortedStations: [ReporterStation] {
        reporter.stations.values.sorted { $0.lastUpdate > $1.lastUpdate }
    }
    
    func stationColor(_ station: ReporterStation) -> Color {
        if station.transmitting { return .red }
        if let lastRx = station.lastRxCallsign, !lastRx.isEmpty { return .green }
        return .blue
    }
}
```

---

## 4. 頻率輸入設計

由於 iOS App 是 SWL（純接收），沒有 CAT 控制無線電，使用者需要手動輸入頻率。

### 4.1 頻率輸入 UI

提供常用 FreeDV 頻率的快捷選擇 + 自訂輸入：

```swift
struct FrequencyPicker: View {
    @Binding var frequencyHz: UInt64
    @State private var customKHz: String = ""
    
    // 常見 FreeDV 頻率（kHz）
    let commonFrequencies: [(String, UInt64)] = [
        ("20m - 14.236 MHz", 14_236_000),
        ("40m - 7.177 MHz",   7_177_000),
        ("80m - 3.625 MHz",   3_625_000),
        ("15m - 21.313 MHz", 21_313_000),
        ("10m - 28.330 MHz", 28_330_000),
        ("17m - 18.118 MHz", 18_118_000),
    ]
    
    var body: some View {
        Section("接收頻率") {
            // 快捷選擇
            ForEach(commonFrequencies, id: \.1) { name, freq in
                Button {
                    frequencyHz = freq
                } label: {
                    HStack {
                        Text(name)
                        Spacer()
                        if frequencyHz == freq {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                }
                .foregroundColor(.primary)
            }
            
            // 自訂輸入
            HStack {
                Text("自訂 (kHz)")
                TextField("14236", text: $customKHz)
                    .keyboardType(.decimalPad)
                    .onSubmit {
                        if let kHz = Double(customKHz) {
                            frequencyHz = UInt64(kHz * 1000)
                        }
                    }
                Button("設定") {
                    if let kHz = Double(customKHz) {
                        frequencyHz = UInt64(kHz * 1000)
                    }
                }
            }
        }
    }
}
```

### 4.2 頻率變更時自動通知 Reporter

```swift
// TransceiverViewModel 中
var frequencyHz: UInt64 = 14_236_000 {
    didSet {
        if frequencyHz != oldValue {
            reporter.frequencyHz = frequencyHz
            reporter.sendFreqChange()
        }
    }
}
```

---

## 5. 背景執行與重連

### 5.1 背景處理

當 App 進入背景（螢幕關閉等），需要考慮：
- 如果音訊仍在 AVAudioEngine 中處理（`UIBackgroundModes: audio`），Socket.IO 連線也需要維持
- Socket.IO-Client-Swift 預設在背景會被暫停，需設定 `reconnects: true`

```swift
manager = SocketManager(
    socketURL: serverURL,
    config: [
        .reconnects(true),
        .reconnectWait(5),          // 5 秒後重連
        .reconnectWaitMax(30),      // 最多等 30 秒
        .forceWebsockets(true)
    ]
)
```

### 5.2 重連後重送狀態

```swift
socket.on(clientEvent: .reconnect) { [weak self] _, _ in
    // 重連後需要等 connection_successful 再重送狀態
    // setupEventHandlers 中的 connection_successful handler 已經會處理
}
```

### 5.3 網路切換

監聽 NWPathMonitor 處理 WiFi ↔ 行動數據切換：

```swift
import Network

private let monitor = NWPathMonitor()

func startNetworkMonitoring() {
    monitor.pathUpdateHandler = { [weak self] path in
        if path.status == .satisfied {
            // 網路恢復，觸發重連
            if self?.isConnected == false {
                self?.connect()
            }
        }
    }
    monitor.start(queue: DispatchQueue.global(qos: .utility))
}
```

---

## 6. UserDefaults 持久化

```swift
// 儲存 Reporter 設定
extension UserDefaults {
    var reporterCallsign: String {
        get { string(forKey: "reporter_callsign") ?? "" }
        set { set(newValue, forKey: "reporter_callsign") }
    }
    var reporterGridSquare: String {
        get { string(forKey: "reporter_grid_square") ?? "" }
        set { set(newValue, forKey: "reporter_grid_square") }
    }
    var reporterFrequencyHz: UInt64 {
        get { UInt64(integer(forKey: "reporter_frequency_hz")) }
        set { set(Int(newValue), forKey: "reporter_frequency_hz") }
    }
    var reporterEnabled: Bool {
        get { bool(forKey: "reporter_enabled") }
        set { set(newValue, forKey: "reporter_enabled") }
    }
    var reporterMessage: String {
        get { string(forKey: "reporter_message") ?? "" }
        set { set(newValue, forKey: "reporter_message") }
    }
}
```

---

## 7. SPM 依賴

在 Xcode 中 File → Add Package Dependencies：

```
https://github.com/socketio/socket.io-client-swift.git
```

Branch: `master` 或最新穩定版 tag。

⚠️ **注意：** Socket.IO-Client-Swift 依賴 Starscream（WebSocket 庫）。如果有衝突或想要更小的依賴樹，可以改用 URLSessionWebSocketTask 自己實作 Engine.IO/Socket.IO 協議。Peter Marks 在 radae_decoder 中就是這樣做的（`socket_io.cpp` 約 300 行，手動解析 Engine.IO frame）。

---

## 8. 開發順序

### Phase 1：Socket.IO 連線基礎
- [ ] SPM 引入 Socket.IO-Client-Swift
- [ ] 建立 FreeDVReporter.swift
- [ ] 實作 connect/disconnect（view-only 模式先行）
- [ ] 驗證：成功連線並收到 bulk_update

### Phase 2：設定 UI
- [ ] SettingsView 加入 Reporter section
- [ ] 呼號、Grid Square、頻率輸入
- [ ] UserDefaults 持久化
- [ ] 連線狀態顯示

### Phase 3：上報功能
- [ ] 實作 report role 連線
- [ ] 發送 freq_change
- [ ] 在 EOO 解碼時發送 rx_report
- [ ] 驗證：在 https://qso.freedv.org 網頁上看到自己的回報

### Phase 4：主畫面整合
- [ ] StatusBar 加入 Reporter 連線指示
- [ ] 呼號解碼時同時回報
- [ ] 頻率變更時自動通知

### Phase 5：在線電台列表（可選）
- [ ] 處理 new_connection / remove_connection / bulk_update
- [ ] 建立 ReporterStationsView
- [ ] 電台狀態即時更新

### Phase 6：穩健性
- [ ] 自動重連
- [ ] 背景執行維持連線
- [ ] 網路切換處理
- [ ] 錯誤處理與用戶提示

---

## 9. 新增/修改檔案清單

```
FreeDV/
├── Network/                            【新增目錄】
│   └── FreeDVReporter.swift            Socket.IO 客戶端 + 事件處理
├── Views/
│   ├── SettingsView.swift              【修改】加入 Reporter 設定 section
│   ├── TransceiverView.swift           【修改】StatusBar 加入連線指示
│   ├── FrequencyPicker.swift           【新增】頻率選擇 UI
│   └── ReporterStationsView.swift      【新增】在線電台列表（可選）
├── ViewModels/
│   └── TransceiverViewModel.swift      【修改】加入 reporter 狀態
├── Audio/
│   └── AudioManager.swift              【修改】EOO 解碼時呼叫 reporter.reportRx()
└── App/
    └── FreeDVApp.swift                 【修改】初始化 FreeDVReporter
```

---

## 10. 參考資源

- **FreeDV Reporter API 文件（Peter Marks 撰寫）：** https://github.com/peterbmarks/radae_decoder/blob/main/FreeDVReporter-API.md
- **radae_decoder 的 C++ 實作：** `src/network/socket_io.h/.cpp` + `src/network/freedv_reporter.h/.cpp`
- **freedv-gui 的 C++ 實作：** `src/reporting/FreeDVReporter.cpp`（使用 IXWebSocket）
- **FreeDV Reporter 網頁：** https://qso.freedv.org
- **Socket.IO-Client-Swift：** https://github.com/socketio/socket.io-client-swift
