import AppKit
import SwiftUI

@MainActor final class CameraImportModel: ObservableObject {
    @Published var source = UserDefaults.standard.string(forKey: "cameraSource") ?? ""
    @Published var destination = UserDefaults.standard.string(forKey: "cameraDestination") ?? ""
    @Published var pattern = UserDefaults.standard.string(forKey: "cameraDatePattern") ?? "yyyymmdd" {
        didSet { UserDefaults.standard.set(pattern, forKey: "cameraDatePattern") }
    }
    @Published var onlyNew = UserDefaults.standard.object(forKey: "cameraOnlyNew") as? Bool ?? true {
        didSet { UserDefaults.standard.set(onlyNew, forKey: "cameraOnlyNew") }
    }
    @Published var running = false
    @Published var progress = DirectoryCopyProgress()
    @Published var messages = ""
    @Published var previousLogURL = TaskLogHistory.latest(.camera)
    var cancellation = CopyCancellation()
    var startBlocker: (() -> String?)?
    private var handle: FileHandle?
    private var logURL: URL?
    private var savedAt = Date.distantPast
    private let stateURL = TaskLogHistory.directory(.camera).deletingLastPathComponent().appendingPathComponent("last-camera-task.json")
    init() {
        progress.text = "请选择存储卡卷和导入目标。"
        if let record = TaskRunRecord.load(from: stateURL) {
            messages = record.restoredMessage.replacingOccurrences(of: "目录复制", with: "相机导入").replacingOccurrences(of: "开始 / 继续复制", with: "开始导入")
            progress.text = messages
        }
    }
    func choose(_ card: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = !card
        panel.prompt = card ? "选择存储卡卷" : "选择导入目标"
        panel.message = card ? "请选择 /Volumes 下的存储卡卷本身，应用会遍历卡内所有相机目录（包含隐藏目录，排除系统服务目录），只读取存储卡。" : "按拍摄日期建立子目录；RAW 放入各日期目录的 RAW 子目录。"
        if card { panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if card {
            let selected = url.resolvingSymlinksInPath().standardizedFileURL
            guard let volume = try? selected.resourceValues(forKeys: [.volumeURLKey]).volume,
                  volume.resolvingSymlinksInPath().standardizedFileURL.path == selected.path,
                  selected.path != "/" else {
                progress.text = "请选择存储卡卷本身，而不是卡内的 DCIM 等文件夹。"; return
            }
            source = url.path; UserDefaults.standard.set(source, forKey: "cameraSource")
        } else { destination = url.path; UserDefaults.standard.set(destination, forKey: "cameraDestination") }
    }
    func addLog(_ text: String) {
        let line = "[\(Date().formatted())] \(text)\n"
        messages += line
        if messages.count > 30000 { messages = String(messages.suffix(24000)) }
        try? handle?.write(contentsOf: Data(line.utf8))
    }
    private func persist(_ status: TaskRunRecord.Status) {
        savedAt = Date()
        let summary = "\(progress.text) 导入 \(progress.copied)，跳过 \(progress.skipped)，失败 \(progress.failed)。"
        do {
            try TaskRunRecord(status: status, text: summary, logPath: logURL?.path, updatedAt: savedAt).save(to: stateURL)
            try handle?.synchronize()
        } catch { addLog("保存任务状态失败：\(error.localizedDescription)") }
    }
    private func accept(_ value: DirectoryCopyProgress) {
        progress = value
        if Date().timeIntervalSince(savedAt) >= 5 { persist(.running) }
    }
    private func finish(_ status: TaskRunRecord.Status) {
        persist(status); running = false
        try? handle?.synchronize(); try? handle?.close(); handle = nil
        previousLogURL = TaskLogHistory.latest(.camera)
    }
    func start() {
        guard !running, !source.isEmpty, !destination.isEmpty else { return }
        if let reason = startBlocker?() { progress.text = reason; return }
        do { _ = try CameraDateRule(pattern) } catch { progress.text = error.localizedDescription; return }
        let input = URL(fileURLWithPath: source), output = URL(fileURLWithPath: destination)
        let rule = pattern, incremental = onlyNew
        cancellation = CopyCancellation(); let control = cancellation
        progress = DirectoryCopyProgress(); progress.text = "正在读取存储卡…"; messages = ""; running = true; logURL = nil
        do {
            let logs = TaskLogHistory.directory(.camera)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let url = logs.appendingPathComponent(UUID().uuidString + ".txt")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw BackupError.message("无法创建导入日志。") }
            handle = try FileHandle(forWritingTo: url); logURL = url
            previousLogURL = TaskLogHistory.latest(.camera, excluding: url)
        } catch { addLog("本机日志不可用：\(error.localizedDescription)") }
        addLog("开始相机导入；只导入新文件：\(incremental ? "开启" : "关闭")；日期规则：\(rule)。")
        persist(.running)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let engine = try CameraImportEngine(source: input, destination: output, pattern: rule, onlyNew: incremental, cancellation: control)
                let result = try engine.run(update: { value in DispatchQueue.main.async { self?.accept(value) } },
                    log: { line in DispatchQueue.main.async { self?.addLog(line) } }, conflict: { folder, names in
                        DispatchQueue.main.sync {
                            guard !control.cancelled else { return .cancel }
                            NSApp.activate(ignoringOtherApps: true)
                            let alert = NSAlert(); alert.messageText = "目标中已有 \(folder) 日期目录"
                            alert.informativeText = "已有目录：\n\(names.prefix(10).joined(separator: "\n"))\(names.count > 10 ? "\n…" : "")\n\n“跳过”将跳过此日期的全部文件（包括 RAW 和视频）。“全部跳过”也会跳过本次其他已有日期目录；新日期仍会导入。“继续导入”会写入规则指定的目录，同名不同内容会保留副本。"
                            alert.addButton(withTitle: "继续导入"); alert.addButton(withTitle: "跳过")
                            alert.addButton(withTitle: "全部跳过"); alert.addButton(withTitle: "停止导入")
                            alert.buttons[0].keyEquivalent = "" // Do not accept a duplicate-date import accidentally with Return.
                            alert.buttons[3].keyEquivalent = "\u{1b}"
                            switch alert.runModal() {
                            case .alertFirstButtonReturn: return .importFiles
                            case .alertSecondButtonReturn: return .skip
                            case .alertThirdButtonReturn: return .skipAll
                            default: return .cancel
                            }
                        }
                    })
                DispatchQueue.main.async {
                    self?.addLog("\(result.text) 导入 \(result.copied)，跳过 \(result.skipped)，失败 \(result.failed)。")
                    self?.finish(control.cancelled ? .stopped : (result.failed == 0 ? .completed : .failed))
                }
            } catch {
                DispatchQueue.main.async {
                    self?.progress.text = "相机导入未完成：\(error.localizedDescription)"
                    self?.addLog(error.localizedDescription); self?.finish(.failed)
                }
            }
        }
    }
    func cancel() { cancellation.cancel(); progress.text = "正在停止导入，已成功文件会保留…" }
    func openLog() {
        previousLogURL = TaskLogHistory.latest(.camera, excluding: running ? logURL : nil)
        if let url = previousLogURL { NSWorkspace.shared.open(url) }
    }
}

struct CameraImportView: View {
    @ObservedObject var model: CameraImportModel
    private var estimate: String {
        guard let seconds = model.progress.remaining, model.running, seconds.isFinite else { return "正在估算…" }
        return seconds < 60 ? "约 \(max(1, Int(seconds))) 秒" : "约 \(Int(seconds / 60)) 分钟"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("相机导入", systemImage: "camera.on.rectangle").font(.largeTitle.bold())
            Text("遍历存储卡，按拍摄日期导入照片、RAW 和视频；不修改或删除卡内文件。").foregroundStyle(.secondary)
            GroupBox("存储卡 → 导入目标") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("存储卡卷").frame(width: 80, alignment: .leading); Text(model.source.isEmpty ? "尚未选择" : model.source).lineLimit(2).textSelection(.enabled); Spacer(); Button("选择存储卡…") { model.choose(true) }.disabled(model.running) }
                    Divider()
                    HStack { Text("目标目录").frame(width: 80, alignment: .leading); Text(model.destination.isEmpty ? "尚未选择" : model.destination).lineLimit(2).textSelection(.enabled); Spacer(); Button("选择目标…") { model.choose(false) }.disabled(model.running) }
                }.padding(10)
            }
            HStack {
                Text("日期目录命名")
                TextField("yyyymmdd", text: $model.pattern).textFieldStyle(.roundedBorder).frame(width: 260).disabled(model.running)
                if let rule = try? CameraDateRule(model.pattern) { Text("示例：\(rule.name(Date())) / RAW").font(.caption).foregroundStyle(.secondary) }
            }
            Text("支持 yyyy、mm、dd，例如 yyyymmdd、yyyy-mm-dd_旅行。优先使用照片／RAW 拍摄日期和带明确时区的视频创建信息；无法可靠读取时使用文件修改日期。").font(.footnote).foregroundStyle(.secondary)
            Toggle("只导入新文件", isOn: $model.onlyNew).disabled(model.running)
            Text("自动记录最近成功文件及逐文件导入记录。已导入且目标仍存在的文件会跳过；成功导入过的日期目录被整体删除后，会记住并跳过旧文件，同一天新拍的文件仍会导入。关闭开关可重新导入。失败或手动跳过的日期仍可重试。相同时间的 JPG 和 RAW 分别记录。").font(.footnote).foregroundStyle(.secondary)
            GroupBox("导入进度") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.progress.text).textSelection(.enabled)
                    if model.running && model.progress.scanning { ProgressView().controlSize(.small) }
                    else if model.progress.totalBytes > 0 { ProgressView(value: Double(min(model.progress.bytes, model.progress.totalBytes)), total: Double(model.progress.totalBytes)) }
                    HStack { Text("导入 \(model.progress.copied)"); Text("跳过 \(model.progress.skipped)"); Text("失败 \(model.progress.failed)"); Spacer(); Text("预计剩余：\(model.running ? estimate : "—")") }.font(.callout)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            HStack {
                Button(model.running ? "正在导入…" : "开始导入") { model.start() }.buttonStyle(.borderedProminent).disabled(model.running || model.source.isEmpty || model.destination.isEmpty)
                Button("停止") { model.cancel() }.disabled(!model.running || model.cancellation.cancelled)
                Spacer()
                Button("打开上次任务日志") { model.openLog() }.disabled(model.previousLogURL == nil)
            }
            ScrollView { Text(model.messages.isEmpty ? "导入结果和失败原因会显示在这里。" : model.messages).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) }.frame(minHeight: 90).background(Color.primary.opacity(0.03)).cornerRadius(8)
        }.padding(28).frame(minWidth: 850, minHeight: 700)
    }
}
