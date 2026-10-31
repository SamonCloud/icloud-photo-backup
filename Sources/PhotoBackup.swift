import AppKit
import SwiftUI
import Photos
import Combine

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func stop() { lock.lock(); value = true; lock.unlock() }
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

struct ProgressState: Sendable {
    var total = 0
    var checked = 0
    var copied = 0
    var skipped = 0
    var failed = 0
    var bytes: Int64 = 0
    var archived = 0
    var restored = 0
    var text = "正在准备…"
}

func runBackup(root: URL, identity: String?, stop: StopFlag, allowCloud: Bool, archiveDeleted: Bool, limit: Int? = nil,
               update: @escaping @Sendable (ProgressState) -> Void,
               log: @escaping @Sendable (String) -> Void,
               remember: @escaping @Sendable (String) -> Void) throws -> ProgressState {
    let archive = try Archive(root: root, expectedIdentity: identity)
    remember(archive.identity)
    _ = try archive.migrateLayout { completed, total in
        update(ProgressState(text: "正在迁移已有备份：\(completed) / \(total) 个资源"))
    }
    if archive.damagedLines > 0 { log("发现 \(archive.damagedLines) 条不完整记录；相应文件会重新核对，不会覆盖旧文件。") }
    let options = PHFetchOptions()
    options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
    options.includeHiddenAssets = true
    options.includeAllBurstAssets = true
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
    let assets = PHAsset.fetchAssets(with: options)
    var initialIdentifiers = Set<String>()
    assets.enumerateObjects { asset, _, _ in initialIdentifiers.insert(asset.localIdentifier) }
    let previouslyBackedUp = Set(archive.receipts.values.filter { $0.deletedOriginalPath == nil }.map(\.assetIdentifier))
    let sourceContinuity = previouslyBackedUp.isEmpty || !previouslyBackedUp.intersection(initialIdentifiers).isEmpty
    var state = ProgressState()
    state.total = limit.map { min($0, assets.count) } ?? assets.count
    update(state)
    let manager = PHAssetResourceManager.default()
    let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "正在备份照片和视频")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    let session = UUID().uuidString
    for index in 0..<state.total {
        if stop.stopped { break }
        try autoreleasepool {
            let asset = assets.object(at: index)
            state.restored += try archive.restoreAsset(asset.localIdentifier)
            let version = String(format: "%.6f", (asset.modificationDate ?? asset.creationDate ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970)
            let resources = PHAssetResource.assetResources(for: asset)
            let baseFilename = resources.first(where: { $0.type == .photo || $0.type == .video })?.originalFilename
                ?? resources.first?.originalFilename ?? "resource"
            let token = archive.token(for: asset.localIdentifier)
            var usedPaths = Set<String>()
            if resources.isEmpty { state.failed += 1; log("未取得资源：\(asset.localIdentifier)") }
            for (resourceIndex, resource) in resources.enumerated() {
                if stop.stopped { break }
                let key = digest("\(asset.localIdentifier)|\(version)|\(resourceIndex)|\(resource.type.rawValue)|\(resource.originalFilename)")
                var path = BackupLayout.path(date: asset.creationDate, baseFilename: baseFilename,
                    originalFilename: resource.originalFilename, type: resource.type.rawValue, token: token)
                if usedPaths.contains(path) {
                    path = BackupLayout.addingSuffix("_r\(resource.type.rawValue)_\(digest(resource.originalFilename).prefix(8))", to: path)
                }
                usedPaths.insert(path)
                if archive.alreadyCopied(key) { state.skipped += 1; continue }
                let dir = root.appendingPathComponent(path).deletingLastPathComponent()
                // Never recreate a disconnected destination or mount point.
                guard FileManager.default.fileExists(atPath: archive.metadata.appendingPathComponent("identity.txt").path) else {
                    throw BackupError.message("目标连接已中断，任务停止。重新挂载后可继续。")
                }
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let staging = archive.stagingDirectory.appendingPathComponent(".partial-\(session)-\(resourceIndex)")
                defer { try? FileManager.default.removeItem(at: staging) }
                state.text = "正在复制：\(resource.originalFilename)"
                update(state)
                let snapshot = state
                let exportError = exportWithFallback(allowNetwork: allowCloud, shouldStop: { stop.stopped }) { network in
                    // A failed PhotoKit request may leave an incomplete target behind.
                    do {
                        if FileManager.default.fileExists(atPath: staging.path) {
                            try FileManager.default.removeItem(at: staging)
                        }
                    } catch { return error }
                    let requestOptions = PHAssetResourceRequestOptions()
                    requestOptions.isNetworkAccessAllowed = network
                    if network {
                        var waiting = snapshot
                        waiting.text = "系统要求联网获取：\(resource.originalFilename)"
                        update(waiting)
                        requestOptions.progressHandler = { progress in
                            var current = snapshot
                            current.text = "正在从 iCloud 获取：\(resource.originalFilename)（\(Int(progress * 100))%）"
                            update(current)
                        }
                    }
                    let semaphore = DispatchSemaphore(value: 0)
                    var result: Error?
                    manager.writeData(for: resource, toFile: staging, options: requestOptions) { error in
                        result = error
                        semaphore.signal()
                    }
                    semaphore.wait()
                    return result
                }
                if let error = exportError {
                    if stop.stopped { break }
                    state.failed += 1
                    let reason = requiresNetwork(error)
                        ? "系统要求联网获取此资源；请勾选“必要时从 iCloud 获取原片”后重试，或在“照片”中完成下载。"
                        : "请检查网络、图库状态和目标目录；详细系统错误如下。"
                    log("复制失败：\(resource.originalFilename)（\(asset.localIdentifier)）\n\(reason)\n\(String(describing: error as NSError))")
                    continue
                }
                // Storage failures abort the run; PhotoKit failures remain retryable.
                let receipt = try archive.commit(staging: staging, relativePath: path, key: key,
                    assetIdentifier: asset.localIdentifier, originalFilename: resource.originalFilename,
                    resourceType: resource.type.rawValue, creationDate: asset.creationDate, modificationDate: asset.modificationDate,
                    assetToken: token)
                if archive.lastCommitReused {
                    state.skipped += 1
                } else {
                    state.copied += 1
                    state.bytes += receipt.bytes
                }
            }
            state.checked += 1
            state.text = "已检查 \(state.checked) / \(state.total) 个照片或视频项目"
            update(state)
        }
    }
    if archiveDeleted && limit == nil && !stop.stopped && state.failed == 0 && state.checked == state.total {
        var currentIdentifiers = Set<String>()
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in currentIdentifiers.insert(asset.localIdentifier) }
        let stable = sourceContinuity && currentIdentifiers == initialIdentifiers && PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
        let result = try archive.reconcileDeleted(liveAssets: currentIdentifiers, fullSuccessfulScan: true, sourceStable: stable,
            shouldStop: { stop.stopped }, stillMissing: { identifier in
                PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized &&
                    PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: options).count == 0
            }, progress: { completed, total in
                var current = state
                current.archived = completed
                current.text = "正在归档源图库已删除的资源：\(completed) / \(total)"
                update(current)
            })
        state.archived = result.archived
        if let warning = result.warning { log(warning) }
    } else if archiveDeleted {
        log("本次为试运行、任务已停止或存在失败资源，不处理删除归档。")
    }
    let completed = limit == nil ? "本次备份完成，归档 \(state.archived) 个资源。" : "试运行完成（前 \(state.total) 个项目），尚未执行全量检查。"
    state.text = stop.stopped ? "已停止，下次可继续补充。" : (state.failed == 0 ? completed : "本次备份结束，仍有失败资源，下次将重试。")
    update(state)
    return state
}

@MainActor final class BackupModel: ObservableObject {
    @Published var destination = UserDefaults.standard.string(forKey: "destination") ?? ""
    @Published var automatic = UserDefaults.standard.object(forKey: "automatic") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automatic, forKey: "automatic") }
    }
    @Published var allowCloud = UserDefaults.standard.object(forKey: "allowCloud") as? Bool ?? true {
        didSet { UserDefaults.standard.set(allowCloud, forKey: "allowCloud") }
    }
    @Published var archiveDeleted = UserDefaults.standard.object(forKey: "archiveDeleted") as? Bool ?? true {
        didSet { UserDefaults.standard.set(archiveDeleted, forKey: "archiveDeleted") }
    }
    @Published var running = false
    @Published var state = ProgressState(text: "请选择备份目录。")
    @Published var messages = ""
    var stop = StopFlag()
    private var errorLog: FileHandle?
    var logURL: URL?
    var startBlocker: (() -> String?)?

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "选作备份目录"
        panel.message = "请选择专用文件夹。NAS 需要先在访达中连接。备份不会删除已有文件。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = url.path
        UserDefaults.standard.set(destination, forKey: "destination")
        UserDefaults.standard.removeObject(forKey: "destinationIdentity")
        state.text = "目标已选择，点击“开始增量备份”。"
    }

    func addLog(_ message: String) {
        let line = "[\(Date().formatted())] \(message)\n"
        messages += line
        if messages.count > 30000 { messages = String(messages.suffix(24000)) }
        try? errorLog?.write(contentsOf: Data(line.utf8))
    }

    func start(limit: Int? = nil) {
        guard !running, !destination.isEmpty else { return }
        if let reason = startBlocker?() { state.text = reason; addLog(reason); return }
        running = true; stop = StopFlag(); messages = ""
        state = ProgressState(text: "正在检查照片访问权限…")
        let root = URL(fileURLWithPath: destination, isDirectory: true)
        let identity = UserDefaults.standard.string(forKey: "destinationIdentity")
        let flag = stop
        let cloud = allowCloud
        let reconcile = archiveDeleted
        let logs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoIncrementalBackup/Logs", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let url = logs.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).txt")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            errorLog = try FileHandle(forWritingTo: url); logURL = url
        } catch { addLog("无法建立本机日志：\(error.localizedDescription)") }
        addLog("开始\(limit == nil ? "完整增量检查" : "前 5 项试运行")；必要时联网获取：\(cloud ? "允许" : "禁止")。")
        Task { [self] in
            let permission = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard permission == .authorized else {
                state.text = "需要完整照片访问权限，才能备份全部内容。"
                addLog("请前往“系统设置 → 隐私与安全性 → 照片”，允许本应用访问全部照片，然后重试。应用只读取图库，不修改图库。")
                finish()
                return
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                do {
                    let result = try runBackup(root: root, identity: identity, stop: flag, allowCloud: cloud, archiveDeleted: reconcile, limit: limit,
                        update: { value in DispatchQueue.main.async { self?.state = value } },
                        log: { text in DispatchQueue.main.async { self?.addLog(text) } },
                        remember: { id in DispatchQueue.main.async { UserDefaults.standard.set(id, forKey: "destinationIdentity") } })
                    DispatchQueue.main.async {
                        self?.addLog("\(result.text) 新复制 \(result.copied) 个资源，跳过 \(result.skipped) 个，失败 \(result.failed) 个，归档 \(result.archived) 个，恢复 \(result.restored) 个。")
                        self?.finish()
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.state.text = "任务未完成：\(error.localizedDescription)"
                        self?.addLog("任务停止：\(error.localizedDescription)")
                        self?.finish()
                    }
                }
            }
        }
    }
    func finish() {
        running = false
        try? errorLog?.synchronize(); try? errorLog?.close(); errorLog = nil
    }
    func cancel() { stop.stop(); state.text = "正在停止，等待当前文件复制结束…" }
}

struct BackupView: View {
    @ObservedObject var model: BackupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 38)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 5) {
                    Text("照片增量备份").font(.largeTitle.bold())
                    Text("从本机系统照片图库复制到移动硬盘或 NAS").foregroundStyle(.secondary)
                }
            }
            Text("关闭此窗口后，应用会留在屏幕顶部菜单栏，正在进行的备份会继续。")
                .font(.footnote).foregroundStyle(.secondary)
            GroupBox("备份位置") {
                HStack {
                    Text(model.destination.isEmpty ? "尚未选择目录" : model.destination)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button("选择目录…") { model.choose() }.disabled(model.running)
                    Button("打开目录") { NSWorkspace.shared.open(URL(fileURLWithPath: model.destination)) }
                        .disabled(model.destination.isEmpty)
                }.padding(8)
            }
            Toggle("以后每次打开应用时，自动开始增量备份", isOn: $model.automatic).disabled(model.running)
            Toggle("必要时从 iCloud 获取原片（先读取本地，仅在系统要求时联网）", isOn: $model.allowCloud).disabled(model.running)
            Toggle("完整检查后，将源图库已删除的项目移入 _deleted 归档目录", isOn: $model.archiveDeleted).disabled(model.running)
            VStack(alignment: .leading, spacing: 12) {
                ProgressView(value: Double(model.state.checked), total: Double(max(1, model.state.total)))
                Text(model.state.text).textSelection(.enabled).lineLimit(3)
                HStack(spacing: 28) {
                    metric("新复制资源", "\(model.state.copied)")
                    metric("已备份，跳过", "\(model.state.skipped)")
                    metric("失败，待重试", "\(model.state.failed)")
                    metric("删除归档", "\(model.state.archived)")
                    metric("本次复制", model.state.bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: model.state.bytes, countStyle: .file))
                }
            }.padding(16).background(Color.primary.opacity(0.04)).cornerRadius(10)
            HStack {
                Button(model.running ? "正在备份…" : "开始增量备份") { model.start() }
                    .buttonStyle(.borderedProminent).disabled(model.running || model.destination.isEmpty)
                Button("停止") { model.cancel() }.disabled(!model.running || model.stop.stopped)
                Button("试运行前 5 项") { model.start(limit: 5) }.disabled(model.running || model.destination.isEmpty)
                Spacer()
                Button("查看本次日志") { if let url = model.logURL { NSWorkspace.shared.open(url) } }
                    .disabled(model.logURL == nil)
            }
            ScrollView {
                Text(model.messages.isEmpty ? "备份错误和完成结果会显示在这里。" : model.messages)
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }.frame(minHeight: 100).background(Color.primary.opacity(0.03)).cornerRadius(8)
            Text("删除以本机系统照片图库已同步的状态为准。完整检查成功后才归档；试运行、中途停止或失败时不处理删除。归档文件可恢复，不会永久删除。")
                .font(.footnote).foregroundStyle(.secondary)
        }.padding(28).frame(minWidth: 760, minHeight: 570)
    }
    func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.monospacedDigit())
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let model = BackupModel()
    let copyModel = CopyModel()
    let navigation = NavigationModel()
    var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var statusSubscription: AnyCancellable?
    private var copySubscription: AnyCancellable?
    private var statusLine: NSMenuItem!
    private var countsLine: NSMenuItem!
    private var startItem: NSMenuItem!
    private var stopItem: NSMenuItem!

    private func menuItem(_ title: String, _ action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "照片增量备份")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel("照片增量备份")
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let heading = menuItem("照片增量备份", nil)
        heading.isEnabled = false
        menu.addItem(heading)
        statusLine = menuItem("尚未开始备份", nil); statusLine.isEnabled = false
        countsLine = menuItem("新复制 0 · 跳过 0 · 失败 0", nil); countsLine.isEnabled = false
        menu.addItem(statusLine); menu.addItem(countsLine)
        menu.addItem(.separator())
        menu.addItem(menuItem("打开备份窗口", #selector(showWindow)))
        startItem = menuItem("开始增量备份", #selector(startBackup))
        stopItem = menuItem("停止本次备份", #selector(stopBackup))
        menu.addItem(startItem); menu.addItem(stopItem)
        menu.addItem(menuItem("打开目标目录", #selector(showDestination)))
        menu.addItem(.separator())
        menu.addItem(menuItem("打开目录复制", #selector(showCopy)))
        menu.addItem(menuItem("开始 / 继续目录复制", #selector(startCopy)))
        menu.addItem(menuItem("停止目录复制", #selector(stopCopy)))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出照片增量备份…", #selector(quitApp)))
        statusItem.menu = menu
        statusSubscription = model.$state.combineLatest(model.$running).sink { [weak self] state, running in
            self?.refreshStatus(state, running: running)
        }
        copySubscription = copyModel.$progress.combineLatest(copyModel.$running).sink { [weak self] progress, running in
            guard let self, !self.model.running else { return }
            if running {
                let percent = progress.totalBytes > 0 ? Int(Double(progress.bytes) / Double(progress.totalBytes) * 100) : 0
                self.statusItem.button?.title = progress.scanning ? " 检查" : " \(percent)%"
                self.statusItem.button?.toolTip = "目录复制：\(progress.text)"
                self.statusLine.title = String(progress.text.prefix(70))
                self.countsLine.title = "已复制 \(progress.copied) · 跳过 \(progress.skipped) · 失败 \(progress.failed)"
            } else { self.refreshStatus(self.model.state, running: false) }
        }
    }

    private func refreshStatus(_ state: ProgressState, running: Bool) {
        let percent = state.total > 0 ? Int(Double(state.checked) / Double(state.total) * 100) : 0
        statusItem.button?.title = running ? " \(percent)%" : ""
        statusItem.button?.toolTip = "照片增量备份：\(state.text)\n新复制 \(state.copied)，跳过 \(state.skipped)，失败 \(state.failed)"
        statusLine.title = running ? "正在备份：\(state.checked) / \(state.total) 项目（\(percent)%）" : String(state.text.prefix(80))
        countsLine.title = "新复制 \(state.copied) · 跳过 \(state.skipped) · 失败 \(state.failed) · 归档 \(state.archived)"
        startItem.isEnabled = !running && !model.destination.isEmpty
        stopItem.isEnabled = running && !model.stop.stopped
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if !copyModel.running || model.running { refreshStatus(model.state, running: model.running) }
    }
    @objc func showCopy() { navigation.tab = 1; showWindow() }
    @objc func startCopy() { showCopy(); copyModel.start() }
    @objc func stopCopy() { copyModel.cancel() }
    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func startBackup() { model.start() }
    @objc func stopBackup() { model.cancel() }
    @objc func showDestination() {
        guard !model.destination.isEmpty else { showWindow(); return }
        NSWorkspace.shared.open(URL(fileURLWithPath: model.destination))
    }
    @objc func quitApp() { NSApp.terminate(nil) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        func overlaps(_ first: String, _ second: String) -> Bool {
            guard !first.isEmpty, !second.isEmpty else { return false }
            let a = URL(fileURLWithPath: first).resolvingSymlinksInPath().path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let b = URL(fileURLWithPath: second).resolvingSymlinksInPath().path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
        }
        copyModel.startBlocker = { [weak self] in
            guard let self else { return nil }
            return self.model.running && (overlaps(self.copyModel.source, self.model.destination) || overlaps(self.copyModel.destination, self.model.destination))
                ? "照片备份正在使用这个目录，请等其停止后再执行目录复制。" : nil
        }
        model.startBlocker = { [weak self] in
            guard let self else { return nil }
            return self.copyModel.running && (overlaps(self.copyModel.source, self.model.destination) || overlaps(self.copyModel.destination, self.model.destination))
                ? "目录复制正在使用这个备份位置，请等其停止后再执行照片备份。" : nil
        }
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu(); item.submenu = appMenu
        appMenu.addItem(withTitle: "退出照片增量备份", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); menu.addItem(editItem)
        let edit = NSMenu(title: "编辑"); editItem.submenu = edit
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 830),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "照片增量备份"
        window.contentMinSize = NSSize(width: 920, height: 790)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ApplicationTabs(navigation: navigation, photo: model, copy: copyModel))
        installStatusItem()
        window.center(); showWindow()
        if let index = CommandLine.arguments.firstIndex(of: "--ui-smoke-test"), CommandLine.arguments.count > index + 1 {
            guard NSRunningApplication.current.activationPolicy == .regular,
                  Bundle.main.url(forResource: "AppIcon", withExtension: "icns") != nil else {
                fputs("UI smoke failed: Dock policy or bundled icon is missing.\n", stderr)
                exit(1)
            }
            print("PASS: regular activation policy and bundled Dock icon.")
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            model.destination = "/Volumes/NAS/照片备份"
            copyModel.source = "/源目录示例"; copyModel.destination = "/Volumes/NAS/目标目录示例"
            navigation.tab = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.savePreview(to: output.appendingPathComponent("directory-tab.png"))
                self.navigation.tab = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.savePreview(to: output.appendingPathComponent("photo-tab.png"))
                    NSApp.terminate(nil)
                }
            }
        } else if model.automatic && !model.destination.isEmpty { model.start() }
    }
    private func savePreview(to url: URL) {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: image)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: image.pixelsWide, pixelsHigh: image.pixelsHigh,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
            NSColor.white.setFill()
            let bounds = NSRect(x: 0, y: 0, width: image.pixelsWide, height: image.pixelsHigh)
            bounds.fill(); image.draw(in: bounds)
            NSGraphicsContext.restoreGraphicsState()
            try canvas.representation(using: .png, properties: [:])?.write(to: url)
        } catch { fputs("UI preview failed: \(error)\n", stderr) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.running || copyModel.running {
            window.makeKeyAndOrderFront(nil)
            if model.running { model.cancel() }
            if copyModel.running { copyModel.cancel() }
            model.addLog("请等待当前文件结束，再退出应用。已完成的资源已记录，下次会继续。")
            return .terminateCancel
        }
        return .terminateNow
    }
}

@main struct PhotoBackupMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
