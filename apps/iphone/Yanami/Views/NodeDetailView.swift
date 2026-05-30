import WebKit
import Combine
import SwiftUI
import Charts

struct NodeDetailView: View {
    @EnvironmentObject private var store: AppStore
    let nodeId: String

    var body: some View {
        List {
            if store.nodeDetail.isLoading && store.nodeDetail.node == nil {
                ProgressView("Loading detail")
            } else if let node = store.nodeDetail.node {
                Section {
                    NodeHeaderView(node: node)
                }

                if let error = store.nodeDetail.error {
                    Section {
                        Label {
                            Text(error)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                        }
                        .font(.caption)
                    }
                }

                Section("Live Resources") {
                    HStack {
                        CircularUsageIndicator(
                            label: "CPU",
                            percent: node.cpuUsage,
                            detail: node.cpuCores > 0 ? "\(node.cpuCores) Core" : ""
                        )
                        Spacer()
                        CircularUsageIndicator(
                            label: "RAM",
                            percent: node.memTotal > 0 ? Double(node.memUsed) / Double(node.memTotal) * 100 : 0,
                            detail: "\(Formatters.bytes(node.memUsed)) / \(Formatters.bytes(node.memTotal))"
                        )
                        Spacer()
                        CircularUsageIndicator(
                            label: "DISK",
                            percent: node.diskTotal > 0 ? Double(node.diskUsed) / Double(node.diskTotal) * 100 : 0,
                            detail: "\(Formatters.bytes(node.diskUsed)) / \(Formatters.bytes(node.diskTotal))"
                        )
                    }
                    .padding(.vertical, 8)
                    
                    if let traffic = node.trafficUsage {
                        ResourceMeter(
                            title: "Traffic Limit",
                            value: traffic.percent,
                            label: "\(Formatters.bytes(traffic.used)) / \(Formatters.bytes(node.trafficLimit))"
                        )
                    }
                }

                Section("System") {
                    DetailLine("UUID", store.settings.maskIpEnabled ? Formatters.maskIpOrUuid(node.uuid) : node.uuid)
                    DetailLine("CPU", [node.cpuName, node.cpuCores > 0 ? "\(node.cpuCores) cores" : ""].filter { !$0.isEmpty }.joined(separator: " / "))
                    DetailLine("Kernel", node.kernelVersion)
                    DetailLine("Virtualization", node.virtualization)
                    DetailLine("Arch", node.arch)
                    DetailLine("GPU", node.gpuName)
                    DetailLine("Uptime", Formatters.uptime(node.uptime))
                    DetailLine("Load", "\(Formatters.number(node.load1, digits: 2)) / \(Formatters.number(node.load5, digits: 2)) / \(Formatters.number(node.load15, digits: 2))")
                    DetailLine("Connections", "TCP \(node.connectionsTcp), UDP \(node.connectionsUdp)")
                    DetailLine("Processes", "\(node.process)")
                    if let expiredAt = node.expiredAt, !expiredAt.isEmpty {
                        DetailLine("Expires", expiredAt)
                    }
                }

                Section("Load Records") {
                    Picker("Range", selection: Binding(
                        get: { store.nodeDetail.loadHours },
                        set: { store.setLoadHours($0) }
                    )) {
                        Text("Realtime").tag(0)
                        Text("1h").tag(1)
                        Text("6h").tag(6)
                        Text("24h").tag(24)
                    }
                    .pickerStyle(.segmented)
                    
                    if !store.nodeDetail.loadRecords.isEmpty {
                        LoadPeakGrid(records: store.nodeDetail.loadRecords)
                        PercentLoadChart(
                            records: store.nodeDetail.loadRecords,
                            animationEnabled: store.settings.chartAnimationEnabled
                        )
                        NetworkLoadChart(
                            records: store.nodeDetail.loadRecords,
                            animationEnabled: store.settings.chartAnimationEnabled
                        )
                        CountLoadChart(
                            records: store.nodeDetail.loadRecords,
                            animationEnabled: store.settings.chartAnimationEnabled
                        )
                    } else {
                        Text("No load records")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    }
                }

                Section("Ping Monitoring") {
                    Picker("Range", selection: Binding(
                        get: { store.nodeDetail.pingHours },
                        set: { store.setPingHours($0) }
                    )) {
                        Text("1h").tag(1)
                        Text("6h").tag(6)
                        Text("24h").tag(24)
                    }
                    .pickerStyle(.segmented)
                    
                    if !store.nodeDetail.pingTasks.isEmpty {
                        ForEach(store.nodeDetail.pingTasks) { task in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(task.name)
                                        .font(.subheadline.bold())
                                    Spacer()
                                    Text("\(Formatters.number(task.latest))ms / \(Formatters.percent(task.loss))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                let taskRecords = store.nodeDetail.pingRecords.filter { $0.taskId == task.id }
                                if !taskRecords.isEmpty {
                                    PingChart(
                                        records: taskRecords,
                                        animationEnabled: store.settings.chartAnimationEnabled
                                    )
                                        .frame(height: 100)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } else {
                        Text("No ping tasks")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    }
                }
            } else if let error = store.nodeDetail.error {
                EmptyStateView(title: "Load Failed", systemImage: "exclamationmark.triangle", message: error)
            }
        }
        .navigationTitle(store.nodeDetail.node?.name ?? "Node Detail")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if let server = store.activeServer, let node = store.nodeDetail.node, node.isOnline, server.authType != .guest {
                    NavigationLink {
                        TerminalNavigationWrapper(uuid: node.uuid, server: server)
                    } label: {
                        Image(systemName: "terminal")
                    }
                }
            }
        }
        .refreshable {
            await store.loadNodeDetail(uuid: nodeId)
        }
        .task(id: detailRefreshTaskID) {
            await store.loadNodeDetail(uuid: nodeId)
            await runDetailRefreshLoop()
        }
    }

    private var detailRefreshTaskID: String {
        "\(nodeId)-\(store.nodeDetail.loadHours)"
    }

    private func runDetailRefreshLoop() async {
        while !Task.isCancelled {
            let realtime = store.nodeDetail.loadHours == 0
            let seconds = realtime ? max(store.settings.refreshIntervalSeconds, 1) : max(store.settings.refreshIntervalSeconds, 30)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await store.refreshNodeDetailRecords()
        }
    }
}

private struct LoadPeakGrid: View {
    let records: [LoadRecord]

    var body: some View {
        let peaks = LoadPeaks(records: records)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
            PeakTile(title: "CPU Peak", value: "\(Formatters.number(peaks.cpu, digits: 1))%")
            PeakTile(title: "RAM Peak", value: "\(Formatters.number(peaks.ram, digits: 1))%")
            PeakTile(title: "Disk Peak", value: "\(Formatters.number(peaks.disk, digits: 1))%")
            PeakTile(title: "Down Peak", value: Formatters.rate(Int64(peaks.netIn)))
            PeakTile(title: "Up Peak", value: Formatters.rate(Int64(peaks.netOut)))
            PeakTile(title: "TCP Peak", value: "\(peaks.tcp)")
            PeakTile(title: "UDP Peak", value: "\(peaks.udp)")
            PeakTile(title: "Process Peak", value: "\(peaks.process)")
        }
        .padding(.vertical, 4)
    }
}

private struct PeakTile: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct PercentLoadChart: View {
    let records: [LoadRecord]
    let animationEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LoadChartHeader(
                title: "Usage Percent",
                systemImage: "gauge.medium",
                items: [
                    LoadChartLegendItem(title: "CPU", systemImage: "cpu", color: .blue),
                    LoadChartLegendItem(title: "RAM", systemImage: "memorychip", color: .green),
                    LoadChartLegendItem(title: "Disk", systemImage: "internaldrive", color: .purple)
                ]
            )

            Chart {
                ForEach(records) { record in
                    LineMark(
                        x: .value("Time", parseISO8601(record.time)),
                        y: .value("CPU", record.cpu),
                        series: .value("Metric", "CPU")
                    )
                    .foregroundStyle(.blue)

                    LineMark(
                        x: .value("Time", parseISO8601(record.time)),
                        y: .value("RAM", record.ramPercent),
                        series: .value("Metric", "RAM")
                    )
                    .foregroundStyle(.green)

                    LineMark(
                        x: .value("Time", parseISO8601(record.time)),
                        y: .value("Disk", record.diskPercent),
                        series: .value("Metric", "Disk")
                    )
                    .foregroundStyle(.purple)
                }
            }
            .frame(height: 170)
            .chartLegend(.hidden)
            .chartYScale(domain: 0...100)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(formatLoadAxisDate(date))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let percent = value.as(Double.self) {
                            Text("\(Int(percent))%")
                        }
                    }
                }
            }
            .chartAnimation(animationEnabled, value: records)
        }
        .padding(.vertical, 8)
    }
}

private struct NetworkLoadChart: View {
    let records: [LoadRecord]
    let animationEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LoadChartHeader(
                title: "Network Rate",
                systemImage: "arrow.down.arrow.up",
                items: [
                    LoadChartLegendItem(title: "Download", systemImage: "arrow.down", color: .blue),
                    LoadChartLegendItem(title: "Upload", systemImage: "arrow.up", color: .orange)
                ]
            )

            Chart {
                ForEach(records) { record in
                    LineMark(
                        x: .value("Time", parseISO8601(record.time)),
                        y: .value("Download", Double(record.netIn)),
                        series: .value("Metric", "Download")
                    )
                    .foregroundStyle(.blue)

                    LineMark(
                        x: .value("Time", parseISO8601(record.time)),
                        y: .value("Upload", Double(record.netOut)),
                        series: .value("Metric", "Upload")
                    )
                    .foregroundStyle(.orange)
                }
            }
            .frame(height: 155)
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(formatLoadAxisDate(date))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let rate = value.as(Double.self) {
                            Text(Formatters.rate(Int64(rate)))
                        }
                    }
                }
            }
            .chartAnimation(animationEnabled, value: records)
        }
        .padding(.vertical, 8)
    }
}

private struct CountLoadChart: View {
    let records: [LoadRecord]
    let animationEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LoadChartHeader(
                title: "Connections & Processes",
                systemImage: "number",
                items: [
                    LoadChartLegendItem(title: "TCP", systemImage: "network", color: .blue),
                    LoadChartLegendItem(title: "UDP", systemImage: "point.3.connected.trianglepath.dotted", color: .cyan),
                    LoadChartLegendItem(title: "Process", systemImage: "gearshape.2", color: .red)
                ]
            )

            Chart {
                ForEach(records) { record in
                    LineMark(
                        x: .value("Time", parseISO8601(record.time)),
                        y: .value("TCP", Double(record.connections)),
                        series: .value("Metric", "TCP")
                    )
                    .foregroundStyle(.blue)

                    LineMark(
                        x: .value("Time", parseISO8601(record.time)),
                        y: .value("UDP", Double(record.connectionsUdp)),
                        series: .value("Metric", "UDP")
                    )
                    .foregroundStyle(.cyan)

                    LineMark(
                        x: .value("Time", parseISO8601(record.time)),
                        y: .value("Process", Double(record.process)),
                        series: .value("Metric", "Process")
                    )
                    .foregroundStyle(.red)
                }
            }
            .frame(height: 155)
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(formatLoadAxisDate(date))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let count = value.as(Double.self) {
                            Text("\(Int(count))")
                        }
                    }
                }
            }
            .chartAnimation(animationEnabled, value: records)
        }
        .padding(.vertical, 8)
    }
}

private struct LoadChartLegendItem {
    let title: String
    let systemImage: String
    let color: Color
}

private struct LoadChartHeader: View {
    let title: String
    let systemImage: String
    let items: [LoadChartLegendItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(title)
                    .font(.subheadline.bold())
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(.blue)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], alignment: .leading, spacing: 6) {
                ForEach(items, id: \.title) { item in
                    Label {
                        Text(item.title)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } icon: {
                        Image(systemName: item.systemImage)
                            .foregroundStyle(item.color)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct LoadPeaks {
    let cpu: Double
    let ram: Double
    let disk: Double
    let netIn: Double
    let netOut: Double
    let tcp: Int
    let udp: Int
    let process: Int

    init(records: [LoadRecord]) {
        cpu = records.map(\.cpu).max() ?? 0
        ram = records.map(\.ramPercent).max() ?? 0
        disk = records.map(\.diskPercent).max() ?? 0
        netIn = Double(records.map(\.netIn).max() ?? 0)
        netOut = Double(records.map(\.netOut).max() ?? 0)
        tcp = records.map(\.connections).max() ?? 0
        udp = records.map(\.connectionsUdp).max() ?? 0
        process = records.map(\.process).max() ?? 0
    }
}

private struct PingChart: View {
    let records: [PingRecord]
    let animationEnabled: Bool
    
    var body: some View {
        Chart {
            ForEach(records) { record in
                LineMark(
                    x: .value("Time", parseISO8601(record.time)),
                    y: .value("Latency", record.value)
                )
                .foregroundStyle(.orange)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .chartAnimation(animationEnabled, value: records)
    }
}

private func formatLoadAxisDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd HH:mm:ss"
    return formatter.string(from: date)
}

private func parseISO8601(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string) ?? Date()
}

private extension View {
    @ViewBuilder
    func chartAnimation<Value: Equatable>(_ enabled: Bool, value: Value) -> some View {
        if enabled {
            self.animation(.default, value: value)
        } else {
            self.transaction { transaction in
                transaction.animation = nil
            }
        }
    }
}


private struct TerminalNavigationWrapper: View {
    let uuid: String
    let server: ServerProfile
    @EnvironmentObject private var store: AppStore
    @State private var token: String?
    @State private var error: String?

    var body: some View {
        Group {
            if let token = token {
                SshTerminalView(viewModel: SshTerminalViewModel(uuid: uuid, server: server, token: token))
            } else if let error = error {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.red)
                    Text(error)
                        .padding()
                    Button("Retry") {
                        Task { await resolveToken() }
                    }
                }
            } else {
                ProgressView("Preparing terminal...")
            }
        }
        .task {
            await resolveToken()
        }
    }

    private func resolveToken() async {
        do {
            let client = KomariClient(profile: server)
            switch server.authType {
            case .guest:
                error = "Guest mode not supported"
            case .apiKey:
                let apiKey = server.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if apiKey.isEmpty {
                    error = "API Key is required"
                } else {
                    token = apiKey
                }
            case .password:
                if !server.sessionToken.isEmpty {
                    token = server.sessionToken
                } else {
                    token = try await client.login()
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct NodeHeaderView: View {
    let node: KomariNode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(node.name)
                    .font(.title3.bold())
                Spacer()
                StatusBadge(isOnline: node.isOnline)
            }
            Text([node.region, node.group, node.os].filter { !$0.isEmpty }.joined(separator: " / "))
                .foregroundStyle(.secondary)
            HStack {
                Label(Formatters.rate(node.netIn), systemImage: "arrow.down")
                Spacer()
                Label(Formatters.rate(node.netOut), systemImage: "arrow.up")
            }
            .font(.caption)
        }
    }
}


@MainActor
final class SshTerminalViewModel: ObservableObject {
    @Published var isConnecting = true
    @Published var isConnected = false
    @Published var error: String?
    @Published var ctrlActive = false
    @Published var altActive = false
    
    private let uuid: String
    private let server: ServerProfile
    private let token: String
    private var urlSession: URLSession?
    private var urlSessionDelegate: URLSessionDelegate?
    private var webSocketTask: URLSessionWebSocketTask?
    private var heartbeatTimer: Timer?
    private var didSendInitialDirectory = false
    private var isDisconnecting = false
    private var lastTerminalSize: (cols: Int, rows: Int)?
    
    init(uuid: String, server: ServerProfile, token: String) {
        self.uuid = uuid
        self.server = server
        self.token = token
    }
    
    func connect() {
        closeConnection(sendCloseFrame: false)
        isDisconnecting = false
        self.isConnecting = true
        self.isConnected = false
        self.error = nil

        guard let url = buildTerminalURL() else {
            self.error = "Invalid terminal URL"
            self.isConnecting = false
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue("YanamiNext-iPhone/1.0", forHTTPHeaderField: "User-Agent")
        server.sanitizedCustomHeaders.forEach { header in
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        switch server.authType {
        case .password:
            let existingCookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            let sessionCookie = "session_token=\(token)"
            request.setValue(existingCookie.isEmpty ? sessionCookie : "\(existingCookie); \(sessionCookie)", forHTTPHeaderField: "Cookie")
        case .apiKey:
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .guest:
            break
        }
        request.setValue(buildOrigin(), forHTTPHeaderField: "Origin")
        
        let session: URLSession
        if server.allowInsecureTLS {
            let delegate = KomariInsecureTLSDelegate(allowedHost: url.host)
            urlSessionDelegate = delegate
            session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        } else {
            urlSessionDelegate = nil
            session = URLSession(configuration: .default)
        }
        urlSession = session
        let task = session.webSocketTask(with: request)
        webSocketTask = task
        didSendInitialDirectory = false
        task.resume()

        receiveMessage(for: task)
        startHeartbeat()
    }
    
    func disconnect() {
        isDisconnecting = true
        closeConnection(sendCloseFrame: true)
        isConnected = false
    }
    
    func sendInput(_ data: Data) {
        let message = URLSessionWebSocketTask.Message.data(data)
        webSocketTask?.send(message) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, !self.isDisconnecting else { return }
                self.isConnected = false
                self.error = error.localizedDescription
            }
        }
    }
    
    func sendText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        sendInput(data)
    }
    
    func sendResize(cols: Int, rows: Int) {
        let cols = max(cols, 1)
        let rows = max(rows, 1)
        lastTerminalSize = (cols, rows)
        sendResizeMessage(cols: cols, rows: rows)
    }

    private func sendResizeMessage(cols: Int, rows: Int) {
        let json: [String: Any] = [
            "type": "resize",
            "cols": cols,
            "rows": rows
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json),
           let text = String(data: data, encoding: .utf8) {
            webSocketTask?.send(.string(text)) { _ in }
        }
    }
    
    private func receiveMessage(for task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self = self else { return }
            Task { @MainActor in
                guard self.webSocketTask === task else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleTextMessage(text)
                    case .data(let data):
                        self.handleDataMessage(data)
                    @unknown default:
                        break
                    }
                    self.receiveMessage(for: task)
                case .failure(let error):
                    self.isConnected = false
                    if !self.isDisconnecting {
                        self.error = error.localizedDescription
                        self.isConnecting = false
                    }
                }
            }
        }
    }
    
    private func handleTextMessage(_ text: String) {
        if !isConnected {
            isConnected = true
            isConnecting = false
            sendInitialTerminalStateIfNeeded()
        }
        if let data = text.data(using: .utf8), !looksLikeControlMessage(text) {
            NotificationCenter.default.post(name: .sshTerminalOutput, object: data)
        }
    }
    
    private func handleDataMessage(_ data: Data) {
        if !isConnected {
            isConnected = true
            isConnecting = false
            sendInitialTerminalStateIfNeeded()
        }
        // This will be forwarded to the WebView
        NotificationCenter.default.post(name: .sshTerminalOutput, object: data)
    }
    
    private func sendInitialTerminalStateIfNeeded() {
        if let lastTerminalSize {
            sendResizeMessage(cols: lastTerminalSize.cols, rows: lastTerminalSize.rows)
        }
        sendInitialDirectoryIfNeeded()
    }

    private func sendInitialDirectoryIfNeeded() {
        guard !didSendInitialDirectory else { return }
        didSendInitialDirectory = true
        sendText("cd /root 2>/dev/null || cd /\r")
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard self?.isConnected == true else { return }
                let json = ["type": "heartbeat"]
                if let data = try? JSONSerialization.data(withJSONObject: json),
                   let text = String(data: data, encoding: .utf8) {
                    self?.webSocketTask?.send(.string(text)) { _ in }
                }
            }
        }
    }
    
    private func buildTerminalURL() -> URL? {
        let cleanUuid = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUuid.isEmpty,
              var components = URLComponents(string: server.normalizedBaseURL) else {
            return nil
        }
        if components.scheme == "https" {
            components.scheme = "wss"
        } else if components.scheme == "http" {
            components.scheme = "ws"
        }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedUuid = cleanUuid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cleanUuid
        let terminalPath = ["", basePath, "api/admin/client", encodedUuid, "terminal"]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.percentEncodedPath = "/" + terminalPath
        return components.url
    }

    private func buildOrigin() -> String {
        guard var components = URLComponents(string: server.normalizedBaseURL),
              let scheme = components.scheme,
              let host = components.host else {
            return server.normalizedBaseURL
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.scheme = scheme == "wss" ? "https" : (scheme == "ws" ? "http" : scheme)
        return components.url?.absoluteString.trimmedTrailingSlash() ?? "\(scheme)://\(host)"
    }

    private func looksLikeControlMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return false }
        return trimmed.contains("\"type\"") &&
            (trimmed.contains("heartbeat") || trimmed.contains("resize") || trimmed.contains("ping"))
    }

    private func closeConnection(sendCloseFrame: Bool) {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        if sendCloseFrame {
            webSocketTask?.cancel(with: .normalClosure, reason: nil)
        } else {
            webSocketTask?.cancel()
        }
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        urlSessionDelegate = nil
        didSendInitialDirectory = false
    }
}

extension NSNotification.Name {
    static let sshTerminalOutput = NSNotification.Name("sshTerminalOutput")
}

struct SshTerminalView: View {
    @StateObject var viewModel: SshTerminalViewModel
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingSnippets = false
    
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                TerminalWebView(viewModel: viewModel, fontSize: store.settings.terminalFontSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if viewModel.isConnecting {
                    VStack {
                        ProgressView()
                        Text("Connecting to terminal...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.86))
                } else if let error = viewModel.error {
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.red)
                        Text(error)
                            .padding()
                        Button("Retry") {
                            viewModel.connect()
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.86))
                }
            }
            
            keyboardAccessoryBar
        }
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingSnippets = true
                } label: {
                    Image(systemName: "command")
                }
            }
        }
        .onAppear {
            viewModel.connect()
        }
        .onDisappear {
            viewModel.disconnect()
        }
        .sheet(isPresented: $showingSnippets) {
            SnippetPickerView { snippet in
                viewModel.sendText(snippet.content)
                if snippet.appendEnter {
                    viewModel.sendText("\r")
                }
            }
        }
    }
    
    private var keyboardAccessoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                TerminalKeyButton(title: "Ctrl", isHighlighted: viewModel.ctrlActive) {
                    viewModel.ctrlActive.toggle()
                }
                TerminalKeyButton(title: "Alt", isHighlighted: viewModel.altActive) {
                    viewModel.altActive.toggle()
                }
                TerminalKeyButton(title: "Esc") { viewModel.sendText("\u{1b}") }
                TerminalKeyButton(title: "Tab") { viewModel.sendText("\t") }
                TerminalKeyButton(title: "↑") { viewModel.sendText("\u{1b}[A") }
                TerminalKeyButton(title: "↓") { viewModel.sendText("\u{1b}[B") }
                TerminalKeyButton(title: "←") { viewModel.sendText("\u{1b}[D") }
                TerminalKeyButton(title: "→") { viewModel.sendText("\u{1b}[C") }
            }
            .padding(8)
        }
        .background(.thinMaterial)
    }
}

struct TerminalKeyButton: View {
    let title: String
    var isHighlighted: Bool = false
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.subheadline, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isHighlighted ? Color.accentColor : Color.secondary.opacity(0.2))
                .foregroundColor(isHighlighted ? .white : .primary)
                .cornerRadius(6)
        }
    }
}

struct TerminalWebView: UIViewRepresentable {
    @ObservedObject var viewModel: SshTerminalViewModel
    let fontSize: Int
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = config.userContentController
        controller.add(context.coordinator, name: "terminalInput")
        controller.add(context.coordinator, name: "terminalResize")
        controller.add(context.coordinator, name: "terminalReady")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        context.coordinator.webView = webView
        
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm@5.3.0/css/xterm.css" />
            <script src="https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.js"></script>
            <script src="https://cdn.jsdelivr.net/npm/xterm-addon-fit@0.8.0/lib/xterm-addon-fit.js"></script>
            <style>
                html, body {
                    margin: 0;
                    height: 100%;
                    background: #000;
                    overflow: hidden;
                    touch-action: manipulation;
                    -webkit-user-select: none;
                    user-select: none;
                }
                #terminal { height: 100vh; width: 100vw; }
                #terminal-input {
                    position: fixed;
                    left: 0;
                    top: 0;
                    width: 2px;
                    height: 2px;
                    opacity: 0.01;
                    color: transparent;
                    caret-color: transparent;
                    background: transparent;
                    border: 0;
                    outline: none;
                    padding: 0;
                    resize: none;
                    pointer-events: none;
                }
            </style>
        </head>
        <body>
            <div id="terminal"></div>
            <textarea
                id="terminal-input"
                autocapitalize="off"
                autocomplete="off"
                autocorrect="off"
                spellcheck="false"
                enterkeyhint="enter"
                inputmode="text"
                aria-hidden="true"></textarea>
            <script>
                const terminalElement = document.getElementById('terminal');
                const inputCapture = document.getElementById('terminal-input');
                const useIOSInputCapture =
                    /iPad|iPhone|iPod/.test(navigator.userAgent) ||
                    (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
                const ESC = String.fromCharCode(27);
                const CR = String.fromCharCode(13);
                const TAB = String.fromCharCode(9);
                const DEL = String.fromCharCode(127);

                const term = new Terminal({
                    cursorBlink: true,
                    fontSize: \(fontSize),
                    fontFamily: 'Menlo, Monaco, "Courier New", monospace',
                    scrollback: 1000,
                    disableStdin: useIOSInputCapture,
                    theme: {
                        background: '#000',
                        foreground: '#f2f2f2'
                    }
                });
                const fitAddon = new FitAddon.FitAddon();
                term.loadAddon(fitAddon);
                term.open(terminalElement);

                function postInput(data) {
                    if (!data || data.length === 0) return;
                    window.webkit.messageHandlers.terminalInput.postMessage(data);
                }

                function fitAndReport() {
                    fitAddon.fit();
                    window.webkit.messageHandlers.terminalResize.postMessage({
                        cols: term.cols,
                        rows: term.rows
                    });
                }

                function focusTerminalInput() {
                    if (useIOSInputCapture) {
                        try {
                            inputCapture.focus({ preventScroll: true });
                        } catch (_) {
                            inputCapture.focus();
                        }
                    } else {
                        term.focus();
                    }
                }

                function keySequence(event) {
                    switch (event.key) {
                    case 'ArrowUp': return ESC + '[A';
                    case 'ArrowDown': return ESC + '[B';
                    case 'ArrowRight': return ESC + '[C';
                    case 'ArrowLeft': return ESC + '[D';
                    case 'Home': return ESC + '[H';
                    case 'End': return ESC + '[F';
                    case 'PageUp': return ESC + '[5~';
                    case 'PageDown': return ESC + '[6~';
                    case 'Insert': return ESC + '[2~';
                    case 'Delete': return ESC + '[3~';
                    case 'Escape': return ESC;
                    case 'Tab': return TAB;
                    default: return null;
                    }
                }

                function setupIOSInputCapture() {
                    let composing = false;
                    inputCapture.value = '';

                    inputCapture.addEventListener('compositionstart', () => {
                        composing = true;
                    });

                    inputCapture.addEventListener('compositionend', event => {
                        composing = false;
                        const text = event.data || inputCapture.value;
                        inputCapture.value = '';
                        postInput(text);
                    });

                    inputCapture.addEventListener('beforeinput', event => {
                        if (composing || event.isComposing || event.inputType === 'insertCompositionText') {
                            return;
                        }
                        if (event.inputType === 'deleteContentBackward') {
                            postInput(DEL);
                            event.preventDefault();
                            return;
                        }
                        if (event.inputType === 'insertLineBreak') {
                            postInput(CR);
                            event.preventDefault();
                            return;
                        }
                        if (event.data) {
                            postInput(event.data);
                            event.preventDefault();
                        }
                    });

                    inputCapture.addEventListener('input', () => {
                        if (composing) return;
                        if (inputCapture.value.length > 0) {
                            postInput(inputCapture.value);
                            inputCapture.value = '';
                        }
                    });

                    inputCapture.addEventListener('keydown', event => {
                        const sequence = keySequence(event);
                        if (sequence) {
                            postInput(sequence);
                            event.preventDefault();
                            return;
                        }
                        if ((event.ctrlKey || event.metaKey) && event.key && event.key.length === 1) {
                            const code = event.key.toUpperCase().charCodeAt(0);
                            if (code >= 64 && code <= 95) {
                                postInput(String.fromCharCode(code - 64));
                                event.preventDefault();
                            }
                            return;
                        }
                        if (event.altKey && !event.ctrlKey && !event.metaKey && event.key && event.key.length === 1) {
                            postInput(ESC + event.key);
                            event.preventDefault();
                        }
                    });

                    ['touchstart', 'mousedown', 'click'].forEach(eventName => {
                        terminalElement.addEventListener(eventName, focusTerminalInput);
                    });
                    document.body.addEventListener('touchstart', focusTerminalInput);
                }

                if (useIOSInputCapture) {
                    setupIOSInputCapture();
                } else {
                    term.onData(postInput);
                    terminalElement.addEventListener('mousedown', focusTerminalInput);
                    terminalElement.addEventListener('click', focusTerminalInput);
                }

                window.addEventListener('resize', () => {
                    setTimeout(fitAndReport, 50);
                });

                window.writeToTerminal = function(data) {
                    term.write(new Uint8Array(data));
                };

                window.setTerminalFontSize = function(size) {
                    term.options.fontSize = size;
                    fitAndReport();
                };

                setTimeout(() => {
                    fitAndReport();
                    focusTerminalInput();
                    window.webkit.messageHandlers.terminalReady.postMessage(true);
                }, 100);
            </script>
        </body>
        </html>
        """
        
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.viewModel = viewModel
        context.coordinator.updateFontSize(fontSize)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        let controller = uiView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "terminalInput")
        controller.removeScriptMessageHandler(forName: "terminalResize")
        controller.removeScriptMessageHandler(forName: "terminalReady")
        coordinator.tearDown()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }
    
    class Coordinator: NSObject, WKScriptMessageHandler {
        var viewModel: SshTerminalViewModel
        weak var webView: WKWebView?
        private var cancellables = Set<AnyCancellable>()
        private var isTerminalReady = false
        private var pendingOutput = Data()
        private var currentFontSize: Int?
        
        init(viewModel: SshTerminalViewModel) {
            self.viewModel = viewModel
            super.init()
            
            NotificationCenter.default.publisher(for: .sshTerminalOutput)
                .sink { [weak self] notification in
                    if let data = notification.object as? Data {
                        self?.writeToWebView(data)
                    }
                }
                .store(in: &cancellables)
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "terminalInput", let data = message.body as? String {
                handleInput(data)
            } else if message.name == "terminalResize", let body = message.body as? [String: Any] {
                viewModel.sendResize(
                    cols: Self.intValue(from: body["cols"]) ?? 80,
                    rows: Self.intValue(from: body["rows"]) ?? 24
                )
            } else if message.name == "terminalReady" {
                isTerminalReady = true
                flushPendingOutput()
                if let currentFontSize {
                    evaluateJavaScript("setTerminalFontSize(\(currentFontSize))")
                }
            }
        }

        func updateFontSize(_ fontSize: Int) {
            guard currentFontSize != fontSize else { return }
            currentFontSize = fontSize
            guard isTerminalReady else { return }
            evaluateJavaScript("setTerminalFontSize(\(fontSize))")
        }

        func tearDown() {
            cancellables.removeAll()
            pendingOutput.removeAll()
            webView = nil
        }

        private static func intValue(from value: Any?) -> Int? {
            if let int = value as? Int {
                return int
            }
            if let number = value as? NSNumber {
                return number.intValue
            }
            return nil
        }
        
        private func handleInput(_ input: String) {
            var finalInput = input
            if viewModel.ctrlActive {
                if let firstChar = input.first,
                   firstChar.isLetter,
                   let scalar = firstChar.uppercased().unicodeScalars.first,
                   scalar.value >= 64,
                   scalar.value <= 95,
                   let ctrlScalar = UnicodeScalar(scalar.value - 64) {
                    finalInput = String(Character(ctrlScalar))
                }
                viewModel.ctrlActive = false
            } else if viewModel.altActive {
                finalInput = "\u{1b}" + input
                viewModel.altActive = false
            }
            viewModel.sendText(finalInput)
        }
        
        private func writeToWebView(_ data: Data) {
            guard isTerminalReady else {
                pendingOutput.append(data)
                return
            }
            evaluateTerminalWrite(data)
        }

        private func flushPendingOutput() {
            guard !pendingOutput.isEmpty else { return }
            evaluateTerminalWrite(pendingOutput)
            pendingOutput.removeAll()
        }

        private func evaluateTerminalWrite(_ data: Data) {
            let bytes = [UInt8](data)
            let script = "writeToTerminal(\(bytes))"
            evaluateJavaScript(script)
        }

        private func evaluateJavaScript(_ script: String) {
            DispatchQueue.main.async {
                self.webView?.evaluateJavaScript(script, completionHandler: nil)
            }
        }
    }
}

struct SnippetPickerView: View {
    @EnvironmentObject private var store: AppStore
    let onSelect: (TerminalSnippet) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showingAdd = false
    @State private var newTitle = ""
    @State private var newContent = ""
    @State private var newAppendEnter = true
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(store.settings.snippets) { snippet in
                    Button {
                        onSelect(snippet)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(snippet.title)
                                .font(.headline)
                            Text(snippet.content)
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { indexSet in
                    var newSettings = store.settings
                    newSettings.snippets.remove(atOffsets: indexSet)
                    store.updateSettings(newSettings)
                }
            }
            .navigationTitle("Snippets")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("Add Snippet", isPresented: $showingAdd) {
                TextField("Title", text: $newTitle)
                TextField("Command", text: $newContent)
                Button("Add") {
                    guard !newTitle.isEmpty, !newContent.isEmpty else { return }
                    var newSettings = store.settings
                    newSettings.snippets.append(TerminalSnippet(title: newTitle, content: newContent, appendEnter: newAppendEnter))
                    store.updateSettings(newSettings)
                    newTitle = ""
                    newContent = ""
                }
                Button("Cancel", role: .cancel) {
                    newTitle = ""
                    newContent = ""
                }
            }
        }
    }
}
