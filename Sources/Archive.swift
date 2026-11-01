import Foundation
import CryptoKit
import Darwin

enum BackupError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

func fileHash(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while try autoreleasepool(invoking: {
        guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
        hash.update(data: data)
        return true
    }) {}
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

func fileSize(_ url: URL) throws -> Int64 {
    // URL resource values can cache a previous size when a staging path is reused.
    // lstat always checks the current file and also refuses symbolic links.
    var info = stat()
    guard Darwin.lstat(url.path, &info) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
        throw BackupError.message("目标不是普通文件：\(url.path)")
    }
    return Int64(info.st_size)
}

struct Receipt: Codable {
    let key: String
    var relativePath: String
    let bytes: Int64
    let sha256: String
    let assetIdentifier: String
    let originalFilename: String
    let resourceType: Int
    let creationDate: Date?
    let modificationDate: Date?
    var assetToken: String? = nil
    var layoutVersion: Int? = nil
    var recordedAt: Date? = nil
    var deletedOriginalPath: String? = nil
    var deletedAt: Date? = nil
}

// Each run owns a new append-only journal. A torn last line can never corrupt
// another run, and an uncommitted file is reconciled by its content on retry.
final class Archive {
    let root: URL
    let metadata: URL
    var stagingDirectory: URL { metadata.appendingPathComponent("staging", isDirectory: true) }
    let identity: String
    var receipts: [String: Receipt] = [:]
    private var lockFD: Int32 = -1
    private var journal: FileHandle?
    private var tokensByAsset: [String: String] = [:]
    private var tokenOwners: [String: String] = [:]
    private var keysBySlot: [String: Set<String>] = [:]
    private var keysByAsset: [String: Set<String>] = [:]
    private(set) var damagedLines = 0
    private(set) var lastCommitReused = false

    init(root: URL, expectedIdentity: String? = nil) throws {
        self.root = root.standardizedFileURL
        self.metadata = self.root.appendingPathComponent(".photo-backup", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw BackupError.message("目标目录不可用。请先连接移动硬盘或在访达中挂载 NAS，然后重试。")
        }
        guard !root.pathComponents.contains(where: { $0.lowercased().hasSuffix(".photoslibrary") }) else {
            throw BackupError.message("请选择图库以外的备份目录。")
        }
        let identityURL = metadata.appendingPathComponent("identity.txt")
        if let expected = expectedIdentity {
            guard let actual = try? String(contentsOf: identityURL, encoding: .utf8), actual == expected else {
                throw BackupError.message("目标目录的身份与上次不一致。请检查 NAS 挂载位置，或重新选择目标目录。")
            }
        }
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        lockFD = Darwin.open(metadata.appendingPathComponent("backup.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else { throw BackupError.message("无法创建备份锁，请检查目标写入权限。") }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockFD); lockFD = -1
            throw BackupError.message("目标目录已有备份任务，或此共享目录不支持文件锁。请勿同时运行多个备份任务。")
        }
        if FileManager.default.fileExists(atPath: identityURL.path) {
            identity = try String(contentsOf: identityURL, encoding: .utf8)
        } else {
            identity = UUID().uuidString
            try identity.write(to: identityURL, atomically: true, encoding: .utf8)
        }
        var logs = try FileManager.default.contentsOfDirectory(at: metadata, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let v2 = metadata.appendingPathComponent("records-v2", isDirectory: true)
        if FileManager.default.fileExists(atPath: v2.path) {
            logs += try FileManager.default.contentsOfDirectory(at: v2, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        let decoder = JSONDecoder()
        for log in logs {
            let data = try Data(contentsOf: log)
            for line in data.split(separator: 10) {
                if let receipt = try? decoder.decode(Receipt.self, from: Data(line)),
                   !receipt.relativePath.hasPrefix("/"),
                   !receipt.relativePath.split(separator: "/").contains("..") {
                    if receipt.recordedAt == nil || (receipt.recordedAt ?? .distantPast) >= (receipts[receipt.key]?.recordedAt ?? .distantPast) {
                        receipts[receipt.key] = receipt
                    }
                } else { damagedLines += 1 }
            }
        }
        for receipt in receipts.values {
            keysBySlot[receipt.stableSlot, default: []].insert(receipt.key)
            keysByAsset[receipt.assetIdentifier, default: []].insert(receipt.key)
            if let token = receipt.assetToken {
                tokensByAsset[receipt.assetIdentifier] = token
                tokenOwners[token] = receipt.assetIdentifier
            }
        }
        for asset in Set(receipts.values.map(\.assetIdentifier)).sorted() { _ = token(for: asset) }
        try recoverMove()
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        for partial in try FileManager.default.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil)
            where partial.lastPathComponent.hasPrefix(".partial-") {
            try FileManager.default.removeItem(at: partial)
        }
    }

    deinit {
        try? journal?.close()
        if lockFD >= 0 { flock(lockFD, LOCK_UN); Darwin.close(lockFD) }
    }

    func alreadyCopied(_ key: String) -> Bool {
        guard let receipt = receipts[key], receipt.bytes > 0 else { return false }
        return (try? fileSize(root.appendingPathComponent(receipt.relativePath))) == receipt.bytes
    }

    func append(_ receipt: Receipt) throws {
        var receipt = receipt
        receipt.recordedAt = Date()
        if journal == nil {
            let name = String(format: "%.0f", Date().timeIntervalSince1970 * 1000) + "-" + UUID().uuidString + ".jsonl"
            let directory = metadata.appendingPathComponent("records-v2", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw BackupError.message("无法写入备份记录，请检查 NAS 连接和剩余空间。")
            }
            journal = try FileHandle(forWritingTo: url)
        }
        var data = try JSONEncoder().encode(receipt)
        data.append(10)
        try journal!.write(contentsOf: data)
        try journal!.synchronize()
        receipts[receipt.key] = receipt
        keysBySlot[receipt.stableSlot, default: []].insert(receipt.key)
        keysByAsset[receipt.assetIdentifier, default: []].insert(receipt.key)
    }

    func commit(staging: URL, relativePath: String, key: String, assetIdentifier: String,
                originalFilename: String, resourceType: Int, creationDate: Date?, modificationDate: Date?,
                assetToken: String? = nil) throws -> Receipt {
        lastCommitReused = false
        let bytes = try fileSize(staging)
        guard bytes > 0 else { throw BackupError.message("导出的文件为空，未标记为已备份。") }
        let completedFile = try FileHandle(forWritingTo: staging)
        do { try completedFile.synchronize(); try completedFile.close() }
        catch { try? completedFile.close(); throw error }
        let checksum = try fileHash(staging)
        let slot = BackupLayout.slot(asset: assetIdentifier, type: resourceType, filename: originalFilename)
        let slotReceipts = (keysBySlot[slot] ?? []).compactMap { receipts[$0] }
        if assetToken != nil, let existing = slotReceipts.first(where: {
            $0.stableSlot == slot && !$0.relativePath.hasPrefix("_versions/") &&
            $0.bytes == bytes && $0.sha256 == checksum && alreadyCopied($0.key)
        }), (try? fileHash(root.appendingPathComponent(existing.relativePath))) == checksum {
            try FileManager.default.removeItem(at: staging)
            let receipt = Receipt(key: key, relativePath: existing.relativePath, bytes: bytes, sha256: checksum,
                assetIdentifier: assetIdentifier, originalFilename: originalFilename, resourceType: resourceType,
                creationDate: creationDate, modificationDate: modificationDate, assetToken: assetToken, layoutVersion: 2)
            try append(receipt)
            lastCommitReused = true
            return receipt
        }
        if assetToken != nil {
            let oldPaths = Set(slotReceipts.filter {
                $0.stableSlot == slot && !$0.relativePath.hasPrefix("_versions/") && alreadyCopied($0.key)
            }.map(\.relativePath))
            for oldPath in oldPaths {
                guard let old = slotReceipts.first(where: { $0.relativePath == oldPath }) else { continue }
                let target = availablePath(BackupLayout.versionPath(old), salt: old.key)
                let updates = slotReceipts.filter { $0.relativePath == oldPath }.map { $0.relocating(to: target) }
                try performMove(PendingMove(from: oldPath, to: target, bytes: old.bytes, sha256: old.sha256, updates: updates))
            }
        }
        var path = relativePath
        var destination = root.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: destination.path) {
            if (try? fileSize(destination)) == bytes, (try? fileHash(destination)) == checksum {
                try FileManager.default.removeItem(at: staging)
                lastCommitReused = true
            } else {
                // Preserve any existing file, even if its contents were changed externally.
                path = BackupLayout.addingSuffix("_conflict_" + UUID().uuidString, to: path)
                destination = root.appendingPathComponent(path)
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        if let creationDate { try? FileManager.default.setAttributes([.creationDate: creationDate], ofItemAtPath: destination.path) }
        let receipt = Receipt(key: key, relativePath: path, bytes: bytes, sha256: checksum,
                              assetIdentifier: assetIdentifier, originalFilename: originalFilename,
                              resourceType: resourceType, creationDate: creationDate, modificationDate: modificationDate,
                              assetToken: assetToken, layoutVersion: assetToken == nil ? nil : 2)
        try append(receipt)
        return receipt
    }

    func token(for asset: String) -> String {
        if let existing = tokensByAsset[asset] { return existing }
        let full = digest(asset)
        var length = 12
        while let owner = tokenOwners[String(full.prefix(length))], owner != asset { length += 4 }
        let token = String(full.prefix(length))
        tokensByAsset[asset] = token; tokenOwners[token] = asset
        return token
    }

    func availablePath(_ desired: String, salt: String) -> String {
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent(desired).path) { return desired }
        var path = BackupLayout.addingSuffix("_conflict_\(digest(salt).prefix(12))", to: desired)
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            path = BackupLayout.addingSuffix("_conflict_\(UUID().uuidString)", to: desired)
        }
        return path
    }

    func recoverMove() throws {
        let pending = metadata.appendingPathComponent("pending-move.json")
        if FileManager.default.fileExists(atPath: pending.path) {
            let move = try JSONDecoder().decode(PendingMove.self, from: Data(contentsOf: pending))
            try completeMove(move)
        }
    }

    func performMove(_ move: PendingMove) throws {
        let pending = metadata.appendingPathComponent("pending-move.json")
        try JSONEncoder().encode(move).write(to: pending, options: .atomic)
        try completeMove(move)
    }

    private func completeMove(_ move: PendingMove) throws {
        for path in [move.from, move.to] {
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                throw BackupError.message("迁移清单包含无效路径，已停止。")
            }
        }
        let source = root.appendingPathComponent(move.from)
        let target = root.appendingPathComponent(move.to)
        let fm = FileManager.default
        if fm.fileExists(atPath: source.path) {
            guard !fm.fileExists(atPath: target.path) else { throw BackupError.message("迁移目标已存在，未覆盖：\(move.to)") }
            let observedBytes = try fileSize(source)
            let observedHash = try fileHash(source)
            guard observedBytes == move.bytes, observedHash == move.sha256 else {
                throw BackupError.message("源文件校验不一致，未迁移：\(move.from)；记录 \(move.bytes) 字节 / \(move.sha256.prefix(12))，实际 \(observedBytes) 字节 / \(observedHash.prefix(12))")
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: source, to: target)
        }
        guard try fileSize(target) == move.bytes, try fileHash(target) == move.sha256 else {
            throw BackupError.message("迁移目标校验不一致，已停止：\(move.to)")
        }
        for update in move.updates { try append(update) }
        try fm.removeItem(at: metadata.appendingPathComponent("pending-move.json"))
        // rmdir only removes empty directories; it never recursively deletes content.
        var parent = source.deletingLastPathComponent()
        while parent.path != root.path, parent.path.hasPrefix(root.path + "/") {
            if Darwin.rmdir(parent.path) != 0 { break }
            parent.deleteLastPathComponent()
        }
    }

    func restoreAsset(_ asset: String) throws -> Int {
        let entries = (keysByAsset[asset] ?? []).compactMap { receipts[$0] }.filter { $0.deletedOriginalPath != nil }
        let groups = Dictionary(grouping: entries, by: \.relativePath)
        var restored = 0
        for (source, group) in groups.sorted(by: { $0.key < $1.key }) {
            let first = group[0]
            let target = availablePath(first.deletedOriginalPath!, salt: first.key)
            let updates = group.map { entry -> Receipt in
                var value = entry.relocating(to: target)
                value.deletedOriginalPath = nil; value.deletedAt = nil
                return value
            }
            try performMove(PendingMove(from: source, to: target, bytes: first.bytes, sha256: first.sha256, updates: updates))
            restored += 1
        }
        return restored
    }

    func reconcileDeleted(liveAssets: Set<String>, fullSuccessfulScan: Bool, sourceStable: Bool,
                          shouldStop: () -> Bool = { false }, stillMissing: (String) -> Bool = { _ in true },
                          progress: (Int, Int) -> Void = { _, _ in }) throws -> (archived: Int, warning: String?) {
        guard fullSuccessfulScan, sourceStable, !shouldStop() else {
            return (0, "未完成稳定的完整检查，本次不处理源图库删除。")
        }
        let active = receipts.values.filter { $0.deletedOriginalPath == nil }
        let known = Set(active.map(\.assetIdentifier))
        let missing = known.subtracting(liveAssets)
        guard !missing.isEmpty else { return (0, nil) }
        guard !liveAssets.isEmpty, !known.intersection(liveAssets).isEmpty,
              !(missing.count > 100 && Double(missing.count) / Double(max(1, known.count)) > 0.25) else {
            return (0, "图库为空、来源可能切换或大量项目同时消失，已跳过删除归档；请先核对系统照片图库和同步状态。")
        }
        let date = Date()
        let batch = BackupLayout.dateText(date, "yyyyMMdd_HHmmss")! + "_" + String(UUID().uuidString.prefix(8))
        let groups = Dictionary(grouping: active.filter { missing.contains($0.assetIdentifier) }, by: \.relativePath)
        var moves: [PendingMove] = []
        for (source, group) in groups.sorted(by: { $0.key < $1.key }) {
            let first = group[0]
            let target = "_deleted/\(batch)/\(source)"
            let updates = group.map { entry -> Receipt in
                var value = entry.relocating(to: target)
                value.deletedOriginalPath = entry.relativePath; value.deletedAt = date
                return value
            }
            moves.append(PendingMove(from: source, to: target, bytes: first.bytes, sha256: first.sha256, updates: updates))
        }
        let audit = metadata.appendingPathComponent("deleted-\(batch).json")
        try JSONEncoder().encode(moves).write(to: audit, options: .atomic)
        var archived = 0
        for move in moves {
            if shouldStop() { return (archived, "删除归档已停止，已完成部分保留记录，下次完整检查时继续。") }
            guard stillMissing(move.updates[0].assetIdentifier) else { continue }
            try performMove(move)
            archived += 1
            progress(archived, moves.count)
        }
        return (archived, nil)
    }

    func migrateLayout(progress: (Int, Int) -> Void = { _, _ in }) throws -> Int {
        let planURL = metadata.appendingPathComponent("migration-v2.json")
        var plan: LayoutMigration
        if FileManager.default.fileExists(atPath: planURL.path) {
            plan = try JSONDecoder().decode(LayoutMigration.self, from: Data(contentsOf: planURL))
            if plan.completedAt != nil { return 0 }
        } else {
            let legacy = receipts.values.filter { $0.layoutVersion != 2 }.sorted { $0.key < $1.key }
            guard !legacy.isEmpty else { return 0 }
            let byAsset = Dictionary(grouping: legacy, by: \.assetIdentifier)
            let bySlot = Dictionary(grouping: legacy, by: \.stableSlot)
            var latestKeys = Set<String>()
            for group in bySlot.values {
                let latest = group.max {
                    ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast)
                }!
                latestKeys.insert(latest.key)
            }
            var moves: [PendingMove] = []
            var used = Set<String>()
            for receipt in legacy {
                let group = byAsset[receipt.assetIdentifier]!
                let primary = group.sorted {
                    let lp = [1: 0, 2: 1, 9: 2][$0.resourceType] ?? 3
                    let rp = [1: 0, 2: 1, 9: 2][$1.resourceType] ?? 3
                    return lp == rp ? $0.originalFilename < $1.originalFilename : lp < rp
                }.first!
                let token = token(for: receipt.assetIdentifier)
                var target = BackupLayout.path(date: receipt.creationDate, baseFilename: primary.originalFilename,
                    originalFilename: receipt.originalFilename, type: receipt.resourceType, token: token)
                if !latestKeys.contains(receipt.key) {
                    target = BackupLayout.versionPath(receipt.relocating(to: target, token: token))
                }
                if used.contains(target) { target = BackupLayout.addingSuffix("_r\(receipt.resourceType)_\(digest(receipt.key).prefix(8))", to: target) }
                target = availablePath(target, salt: receipt.key)
                used.insert(target)
                moves.append(PendingMove(from: receipt.relativePath, to: target, bytes: receipt.bytes,
                    sha256: receipt.sha256, updates: [receipt.relocating(to: target, token: token)]))
            }
            plan = LayoutMigration(schema: 2, createdAt: Date(), completedAt: nil, moves: moves)
            try JSONEncoder().encode(plan).write(to: planURL, options: .atomic)
        }
        for (index, move) in plan.moves.enumerated() {
            let done = move.updates.allSatisfy { receipts[$0.key]?.relativePath == $0.relativePath && receipts[$0.key]?.layoutVersion == 2 }
            if !done { try performMove(move) }
            progress(index + 1, plan.moves.count)
        }
        plan.completedAt = Date()
        try JSONEncoder().encode(plan).write(to: planURL, options: .atomic)
        return plan.moves.count
    }
}
