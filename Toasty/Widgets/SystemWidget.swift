import Darwin
import SwiftUI

// MARK: - Sampling

/// This Mac's CPU load and memory, sampled every two seconds while a
/// System widget is on screen (and not at all otherwise). One sampler for
/// every widget: CPU load is the difference between two readings.
@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    /// Busy share of all cores over the last interval, 0–1 (nil until two
    /// readings).
    @Published private(set) var cpu: Double?
    /// The last two minutes of `cpu`, oldest first.
    @Published private(set) var cpuHistory: [Double] = []
    /// Memory in use the way Activity Monitor counts it: app memory, wired
    /// and compressed.
    @Published private(set) var memoryUsed: UInt64 = 0
    let memoryTotal = ProcessInfo.processInfo.physicalMemory

    static let interval: TimeInterval = 2
    static let historyLength = 60

    /// The chip ("Apple M1 Max"), and its cores.
    let chip: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var chars = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &chars, &size, nil, 0)
        let chip = String(cString: chars).trimmingCharacters(in: .whitespaces)
        return chip.isEmpty ? "This Mac" : chip
    }()
    let cores = ProcessInfo.processInfo.processorCount

    private let host = mach_host_self()
    private var pageSize: UInt64 = 16_384
    private var lastTicks: (busy: UInt64, total: UInt64)?
    /// How many widgets on screen show each metric: only those are read.
    private var watchers: [SystemMetric: Int] = [:]
    private var timer: Timer?

    private init() {
        var size: vm_size_t = 0
        if host_page_size(host, &size) == KERN_SUCCESS, size > 0 { pageSize = UInt64(size) }
    }

    var memoryFraction: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }

    private func watching(_ m: SystemMetric) -> Bool { watchers[m, default: 0] > 0 }

    /// A widget on screen showing `metrics` (the disk is read by the widget
    /// itself; it's counted here only so the timer knows).
    func watch(_ metrics: Set<SystemMetric>) {
        let had = (watching(.cpu), watching(.memory))
        for m in metrics where m != .disk { watchers[m, default: 0] += 1 }
        if !had.0 && watching(.cpu) || !had.1 && watching(.memory) { sample() }
        if timer == nil, watching(.cpu) || watching(.memory) {
            let t = Timer(timeInterval: Self.interval, repeats: true) { _ in
                MainActor.assumeIsolated { SystemMonitor.shared.sample() }
            }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    func unwatch(_ metrics: Set<SystemMetric>) {
        for m in metrics where m != .disk { watchers[m] = max(0, watchers[m, default: 0] - 1) }
        if !watching(.cpu) {
            // A fresh start next time: a gap would read as one long average.
            lastTicks = nil
            if cpu != nil { cpu = nil }
            if !cpuHistory.isEmpty { cpuHistory = [] }
        }
        if !watching(.cpu) && !watching(.memory) {
            timer?.invalidate()
            timer = nil
        }
    }

    private func sample() {
        if watching(.cpu), let ticks = cpuTicks() {
            if let last = lastTicks, ticks.total > last.total {
                let load = Double(ticks.busy &- last.busy) / Double(ticks.total - last.total)
                let clamped = min(1, max(0, load))
                cpu = clamped
                cpuHistory.append(clamped)
                if cpuHistory.count > Self.historyLength { cpuHistory.removeFirst(cpuHistory.count - Self.historyLength) }
            }
            lastTicks = ticks
        }
        if watching(.memory), let used = memoryInUse(), used != memoryUsed { memoryUsed = used }
    }

    private func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    private func memoryInUse() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        let pages = app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return pages * pageSize
    }
}

/// The volume a folder is on: its name and how full it is, counting
/// purgeable space as free (as Finder does).
struct DiskSpace: Equatable, Sendable {
    let name: String
    let total: Int64
    let available: Int64

    var used: Int64 { max(0, total - available) }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    nonisolated static func of(_ folder: String) -> DiskSpace? {
        let url = URL(fileURLWithPath: FileManager.default.fileExists(atPath: folder) ? folder : "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey,
                                                         .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity, total > 0 else { return nil }
        return DiskSpace(name: v.volumeName ?? "Disk", total: Int64(total),
                         available: v.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}

// MARK: - Options

enum SystemMetric: String, Codable, CaseIterable, Identifiable {
    case cpu, memory, disk
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        }
    }
}

/// A System widget's options (`SystemOptionsView`), saved with it.
struct SystemOptions: Codable, Equatable {
    /// What a Small shows.
    var glance: SystemMetric = .cpu
    var glanceStyle: WidgetGlanceStyle = .ring
    /// What a Medium or Large leaves out (never all three).
    var hidden: Set<SystemMetric> = []
    /// The disk shown: a volume's mount path, or nil for the workspace's.
    var volume: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        glance = (try? c.decodeIfPresent(SystemMetric.self, forKey: .glance)) ?? .cpu
        glanceStyle = (try? c.decodeIfPresent(WidgetGlanceStyle.self, forKey: .glanceStyle)) ?? .ring
        hidden = (try? c.decodeIfPresent(Set<SystemMetric>.self, forKey: .hidden)) ?? []
        volume = try? c.decodeIfPresent(String.self, forKey: .volume)
    }

    /// The meters a Medium or Large shows, in order.
    var shown: [SystemMetric] {
        let list = SystemMetric.allCases.filter { !hidden.contains($0) }
        return list.isEmpty ? SystemMetric.allCases : list
    }

    /// What a widget of this size reads.
    func metrics(small: Bool) -> Set<SystemMetric> { small ? [glance] : Set(shown) }
}

// MARK: - Widget

/// CPU load, memory in use and a disk, as its options say. Small: one of
/// them as the glance. Medium: their meters. Large: the chip, the meters,
/// and (with CPU) its last two minutes.
struct SystemWidget: View {
    @ObservedObject var workspace: Workspace
    let item: WidgetItem
    let size: WidgetSize
    @ObservedObject private var monitor = SystemMonitor.shared
    @State private var disk: DiskSpace?

    private var options: SystemOptions { item.system }
    private var metrics: Set<SystemMetric> { options.metrics(small: size.kind == .small) }
    private var diskFolder: String? { metrics.contains(.disk) ? options.volume ?? workspace.folder : nil }

    var body: some View {
        VStack(spacing: 0) {
            WidgetHeader(kind: .system)
            switch size.kind {
            case .small: small
            case .medium: meters
            case .large: large
            }
        }
        .onAppear { monitor.watch(metrics) }
        .onDisappear { monitor.unwatch(metrics) }
        .onChange(of: metrics) { old, new in
            monitor.watch(new)
            monitor.unwatch(old)
        }
        .task(id: diskFolder) {
            guard let folder = diskFolder else { disk = nil; return }
            // Disk space changes slowly; every ten seconds is plenty.
            while !Task.isCancelled {
                let d = await Task.detached(priority: .utility) { DiskSpace.of(folder) }.value
                if d != disk { disk = d }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private static func percent(_ f: Double?) -> String {
        f.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }

    private var memoryValue: String {
        "\(Self.gigabytes(monitor.memoryUsed)) of \(Self.gigabytes(monitor.memoryTotal)) GB"
    }

    private static func gigabytes(_ n: UInt64) -> String {
        let gb = Double(n) / 1_073_741_824
        return gb >= 10 ? "\(Int(gb.rounded()))" : String(format: "%.1f", gb)
    }

    /// Finder's units (powers of 1000), as the disk's size is sold.
    private static func diskBytes(_ n: Int64) -> String {
        let gb = Double(n) / 1_000_000_000
        if gb >= 1000 { return String(format: "%.1f TB", gb / 1000) }
        return gb >= 10 ? "\(Int(gb.rounded())) GB" : String(format: "%.1f GB", gb)
    }

    private func meter(_ m: SystemMetric) -> Meter? {
        switch m {
        case .cpu: Meter(id: "cpu", title: "CPU", fraction: monitor.cpu ?? 0, value: "")
        case .memory: Meter(id: "memory", title: "Memory", fraction: monitor.memoryFraction, value: memoryValue)
        case .disk: disk.map { Meter(id: "disk", title: $0.name, fraction: $0.fraction, value: "\(Self.diskBytes($0.available)) free") }
        }
    }

    private var rows: [Meter] { options.shown.compactMap(meter) }

    private var small: some View {
        let glance = options.glance
        let fraction: Double? = switch glance {
        case .cpu: monitor.cpu
        case .memory: monitor.memoryFraction
        case .disk: disk?.fraction
        }
        return WidgetGlance {
            if options.glanceStyle == .ring {
                ContextRing(fraction: fraction, name: glance.title)
                    .padding(.bottom, Theme.Space.xs)
            } else {
                GlanceValue(text: Self.percent(fraction))
            }
        } caption: {
            switch glance {
            case .cpu: "CPU"
            case .memory: "Memory"
            case .disk: disk?.name ?? "Disk"
            }
        } footer: {
            switch glance {
            case .cpu: Text("\(monitor.cores) cores")
            case .memory: Text(memoryValue).monospacedDigit()
            case .disk: Text(disk.map { "\(Self.diskBytes($0.available)) free" } ?? "").monospacedDigit()
            }
        }
    }

    private var meters: some View {
        VStack(spacing: 0) {
            ForEach(rows) { MeterRow(meter: $0) }
            Spacer(minLength: 0)
        }
    }

    private var large: some View {
        VStack(spacing: 0) {
            SummaryLine(text: "\(monitor.chip) · \(monitor.cores) cores")
            ForEach(rows) { MeterRow(meter: $0) }
            if metrics.contains(.cpu) {
                CPUGraph(history: monitor.cpuHistory, length: SystemMonitor.historyLength)
                    .padding(.horizontal, Theme.Widget.edge)
                    .padding(.top, Theme.Space.s)
                    .padding(.bottom, Theme.Space.m)
            } else {
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Options popover

/// A System widget's options, from edit mode: what it shows at its size,
/// and which disk. A choice applies at once; the widget beside it shows it.
struct SystemOptionsView: View {
    let item: WidgetItem
    let set: (SystemOptions) -> Void
    @State private var volumes: [(name: String, path: String)] = []

    private var options: SystemOptions { item.system }
    private var small: Bool { item.span == 1 }

    var body: some View {
        WidgetOptionsForm(title: small ? "Small System Widget" : "System Widget") {
            if small {
                Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.s) {
                    GridRow {
                        WidgetOptionLabel("Show")
                        WidgetOptionChoice(title: "Show", values: SystemMetric.allCases, name: \.title,
                                           selection: binding(\.glance))
                    }
                    GridRow {
                        WidgetOptionLabel("Style")
                        WidgetOptionChoice(title: "Style", values: WidgetGlanceStyle.allCases, name: \.title,
                                           selection: binding(\.glanceStyle))
                    }
                    if options.glance == .disk {
                        GridRow {
                            WidgetOptionLabel("Disk")
                            diskPicker
                        }
                    }
                }
            } else {
                ForEach(SystemMetric.allCases) { m in
                    let on = !options.hidden.contains(m)
                    HStack(spacing: Theme.Space.m) {
                        Text(m.title).font(.toasty(Theme.Size.control))
                        Spacer(minLength: Theme.Space.l)
                        Toggle(m.title, isOn: Binding(get: { on }, set: { want in
                            var o = options
                            if want { o.hidden.remove(m) } else if o.shown.count > 1 { o.hidden.insert(m) }
                            set(o)
                        }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        // One stays on: an empty widget shows nothing.
                        .disabled(on && options.shown.count == 1)
                    }
                    .frame(minHeight: 24)
                    if m == .disk, on { diskPicker }
                }
            }
        }
        .onAppear { volumes = Self.mountedVolumes() }
    }

    private var diskPicker: some View {
        Picker("Disk", selection: binding(\.volume)) {
            Text("Workspace's Disk").tag(String?.none)
            if !volumes.isEmpty { Divider() }
            ForEach(volumes, id: \.path) { v in Text(v.name).tag(Optional(v.path)) }
        }
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }

    private func binding<T>(_ key: WritableKeyPath<SystemOptions, T>) -> Binding<T> {
        Binding(get: { options[keyPath: key] }, set: { var o = options; o[keyPath: key] = $0; set(o) })
    }

    private static func mountedVolumes() -> [(name: String, path: String)] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { u in
            guard let name = try? u.resourceValues(forKeys: [.volumeNameKey]).volumeName else { return nil }
            return (name, u.path)
        }
    }
}

/// The last two minutes of CPU load, newest at the right, on a fixed
/// 0–100% scale.
private struct CPUGraph: View {
    let history: [Double]
    let length: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("CPU, last 2 minutes")
                .font(.toasty(Theme.Size.meta))
                .foregroundStyle(.tertiary)
            GeometryReader { geo in
                let points = Self.points(history, length: length, in: geo.size)
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .fill(Theme.Fill.faint)
                    if let first = points.first, let last = points.last {
                        Path { p in
                            p.move(to: CGPoint(x: first.x, y: geo.size.height))
                            points.forEach { p.addLine(to: $0) }
                            p.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                            p.closeSubpath()
                        }
                        .fill(LinearGradient(colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom))
                        Path { p in p.addLines(points) }
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU over the last two minutes")
    }

    private static func points(_ history: [Double], length: Int, in size: CGSize) -> [CGPoint] {
        guard history.count > 1 else { return [] }
        let step = size.width / CGFloat(max(1, length - 1))
        let start = CGFloat(length - history.count) * step
        let inset: CGFloat = 2
        return history.enumerated().map { i, v in
            CGPoint(x: start + CGFloat(i) * step,
                    y: inset + (size.height - inset * 2) * (1 - CGFloat(v)))
        }
    }
}
