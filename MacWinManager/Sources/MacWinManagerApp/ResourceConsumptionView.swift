import AppKit
import Darwin
import SwiftUI

/// Native process metrics; unsupported process-tree, disk and GPU values stay unavailable.
struct ResourceConsumptionView: View {
    @State private var expanded = false
    @State private var cpuText = "采样中"
    @State private var memoryText = "采样中"
    @State private var previousCPU: Double?
    @State private var previousTime: TimeInterval?
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("CPU \(cpuText) · \(memoryText)") { expanded.toggle() }
                .buttonStyle(.plain)
                .accessibilityLabel("应用资源监控")
                .accessibilityHint("展开或收起资源详情")
            if expanded {
                Text("范围：当前应用主进程；CPU 按整机容量计，内存为当前驻留内存。")
                Text("子进程、磁盘读写、GPU：不可用")
                Text("每 2 秒更新，窗口隐藏或最小化时暂停。")
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(10)
        .frame(maxWidth: expanded ? 290 : nil, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .onReceive(timer) { _ in sample() }
        .onAppear { sample() }
    }

    private func sample() {
        guard !NSApp.isHidden, NSApp.windows.contains(where: { $0.isVisible && !$0.isMiniaturized }) else {
            previousCPU = nil
            previousTime = nil
            return
        }
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            cpuText = "不可用"
            memoryText = "不可用"
            previousCPU = nil
            previousTime = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        if let oldCPU = previousCPU, let oldTime = previousTime, now > oldTime {
            let percent = max(0, min(100, (cpu - oldCPU) / (now - oldTime)
                / Double(max(1, ProcessInfo.processInfo.activeProcessorCount)) * 100))
            cpuText = String(format: "%.1f%%", percent)
        } else {
            cpuText = "采样中"
        }
        previousCPU = cpu
        previousTime = now
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        memoryText = result == KERN_SUCCESS
            ? String(format: "%.1f MiB", Double(info.resident_size) / 1_048_576)
            : "不可用"
    }
}
