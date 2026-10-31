import AppKit
import SwiftUI

@MainActor final class CopyModel: ObservableObject {
    @Published var source = UserDefaults.standard.string(forKey: "copySource") ?? ""
    @Published var destination = UserDefaults.standard.string(forKey: "copyDestination") ?? ""
    @Published var includeHidden = UserDefaults.standard.bool(forKey: "copyHiddenDirectories") {
        didSet { UserDefaults.standard.set(includeHidden, forKey: "copyHiddenDirectories") }
    }
    @Published var keepExtras = UserDefaults.standard.object(forKey: "copyKeepExtras") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepExtras, forKey: "copyKeepExtras") }
    }
    @Published var running = false
    @Published var progress = DirectoryCopyProgress()
    @Published var messages = ""
    var cancellation = CopyCancellation()
    var logURL: URL?
    var startBlocker: (() -> String?)?
    private var logHandle: FileHandle?

    func choose(source choosingSource: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = !choosingSource
        panel.prompt = choosingSource ? "选择源目录" : "选择目标目录"
        panel.message = choosingSource ? "复制所选目录内的内容，不额外套一层源目录名。" : "同名且属性不一致的文件会被替换；目标独有内容保留。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if choosingSource { source = url.path; UserDefaults.standard.set(source, forKey: "copySource") }
        else { destination = url.path; UserDefaults.standard.set(destination, forKey: "copyDestination") }
    }
    func addLog(_ text: String) {
        let line = "[\(Date().formatted())] \(text)\n"
        messages += line
        if messages.count > 30000 { messages = String(messages.suffix(24000)) }
        try? logHandle?.write(contentsOf: Data(line.utf8))
    }
    func start() {
        guard !running, !source.isEmpty, !destination.isEmpty else { return }
        if let reason = startBlocker?() { progress.text = reason; addLog(reason); return }
        cancellation = CopyCancellation()
        let control = cancellation
        let input = URL(fileURLWithPath: source), output = URL(fileURLWithPath: destination)
        let hidden = includeHidden
        let keep = keepExtras
        messages = ""; progress = DirectoryCopyProgress(); running = true
        do {
            let logs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PhotoIncrementalBackup/CopyLogs", isDirectory: true)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let url = logs.appendingPathComponent(UUID().uuidString + ".txt")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw BackupError.message("无法创建复制日志。") }
            logHandle = try FileHandle(forWritingTo: url); logURL = url
        } catch { addLog("本机日志不可用：\(error.localizedDescription)") }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let engine = try DirectoryCopyEngine(source: input, destination: output, includeHidden: hidden, keepExtras: keep, cancellation: control)
                let result = try engine.run(update: { value in DispatchQueue.main.async { self?.progress = value } },
                    log: { line in DispatchQueue.main.async { self?.addLog(line) } })
                DispatchQueue.main.async {
                    self?.addLog("\(result.text) 已复制 \(result.copied)，跳过 \(result.skipped)，失败 \(result.failed)，目标独有项归档 \(result.archivedExtras)。")
                    self?.finish()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.progress.text = "任务未完成：\(error.localizedDescription)"
                    self?.addLog(error.localizedDescription); self?.finish()
                }
            }
        }
    }
    func cancel() { cancellation.cancel(); progress.text = "正在停止，保留当前文件供下次续传…" }
    private func finish() { running = false; try? logHandle?.synchronize(); try? logHandle?.close(); logHandle = nil }
}

@MainActor final class NavigationModel: ObservableObject { @Published var tab = 0 }

struct ApplicationTabs: View {
    @ObservedObject var navigation: NavigationModel
    @ObservedObject var photo: BackupModel
    @ObservedObject var copy: CopyModel
    var body: some View {
        TabView(selection: $navigation.tab) {
            BackupView(model: photo).tabItem { Label("照片备份", systemImage: "photo.on.rectangle") }.tag(0)
            DirectoryCopyView(model: copy).tabItem { Label("目录复制", systemImage: "folder") }.tag(1)
        }.padding(8)
    }
}

struct DirectoryCopyView: View {
    @ObservedObject var model: CopyModel
    func amount(_ bytes: Int64) -> String { bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    var estimate: String {
        guard model.running, let seconds = model.progress.remaining, seconds.isFinite else {
            return model.running ? "正在估算…" : "—"
        }
        let value = Int(seconds)
        if value < 60 { return "约 \(max(1, value)) 秒" }
        if value < 3600 { return "约 \(value / 60) 分钟" }
        return "约 \(value / 3600) 小时 \((value % 3600) / 60) 分钟"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("目录复制", systemImage: "folder.badge.plus").font(.largeTitle.bold())
            Text("按文件名、大小、创建时间和修改时间检查差异；时间仅比较到秒，不一致时替换。")
                .foregroundStyle(.secondary)
            GroupBox("源目录 → 目标目录") {
                VStack(spacing: 12) {
                    pathRow("源目录", model.source, true)
                    Divider()
                    pathRow("目标目录", model.destination, false)
                }.padding(10)
            }
            Toggle("包含隐藏目录", isOn: $model.includeHidden).disabled(model.running)
            Toggle("保留目标独有的文件", isOn: $model.keepExtras).disabled(model.running)
            if !model.keepExtras {
                Text("不保留时，完整复制成功后将目标独有内容移入 .directory-copy-archive，保留按批次恢复的副本。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("默认排除隐藏目录及其内容；隐藏文件仍复制。符号链接按链接复制，不跟随链接遍历。")
                .font(.footnote).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                if model.running && model.progress.scanning { ProgressView().controlSize(.small) }
                else if model.progress.totalBytes > 0 {
                    ProgressView(value: Double(model.progress.bytes), total: Double(max(model.progress.totalBytes, model.progress.bytes)))
                } else {
                    ProgressView(value: Double(model.progress.done), total: Double(max(1, model.progress.total)))
                }
                Text(model.progress.text).textSelection(.enabled).lineLimit(3)
                HStack(spacing: 24) {
                    metric("已复制", "\(model.progress.copied)")
                    metric("属性一致，跳过", "\(model.progress.skipped)")
                    metric("失败", "\(model.progress.failed)")
                    metric("待复制数据进度", "\(amount(model.progress.bytes)) / \(amount(model.progress.totalBytes))")
                    metric("预计剩余", estimate)
                }
            }.padding(16).background(Color.primary.opacity(0.04)).cornerRadius(10)
            HStack {
                Button(model.running ? "正在复制…" : "开始 / 继续复制") { model.start() }
                    .buttonStyle(.borderedProminent).disabled(model.running || model.source.isEmpty || model.destination.isEmpty)
                Button("停止") { model.cancel() }.disabled(!model.running || model.cancellation.cancelled)
                Spacer()
                Button("查看日志") { if let url = model.logURL { NSWorkspace.shared.open(url) } }.disabled(model.logURL == nil)
            }
            ScrollView {
                Text(model.messages.isEmpty ? "复制结果和属性保留失败的原因会显示在这里。" : model.messages)
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }.frame(minHeight: 90).background(Color.primary.opacity(0.03)).cornerRadius(8)
            Text("权限、ACL、扩展属性等仍尽量保留，但不参与成功或跳过判定。真正的读写错误和秒级时间差异仍会报错；大文件可中断续传。")
                .font(.footnote).foregroundStyle(.secondary)
        }.padding(28).frame(minWidth: 850, minHeight: 660)
    }
    func pathRow(_ title: String, _ path: String, _ source: Bool) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            Text(path.isEmpty ? "尚未选择" : path).textSelection(.enabled).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Button("选择…") { model.choose(source: source) }.disabled(model.running)
        }
    }
    func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .medium, design: .monospaced))
        }
    }
}
