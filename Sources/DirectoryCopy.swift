import Foundation
import Darwin
import CryptoKit

final class CopyCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

struct CopyFileStamp: Codable, Equatable {
    let kind: UInt16
    let size: Int64
    let modified: Int64
    let modifiedNano: Int64
    let created: Int64
    let createdNano: Int64
    let mode: UInt16
    let uid: UInt32
    let gid: UInt32
    let flags: UInt32
    let attributes: [String: String]
    let acl: String
    let link: String?

    /// A matching relative path supplies the filename. Type/link checks prevent
    /// confusing a regular file with a directory or a different symbolic link.
    func matchesCopyRequirements(_ other: CopyFileStamp) -> Bool {
        kind == other.kind && size == other.size && created == other.created && modified == other.modified && link == other.link
    }

    /// Resume safety remains subsecond-sensitive for the source, independently
    /// of the relaxed source/destination comparison. Old checkpoints stay usable.
    func sameSourceVersion(_ other: CopyFileStamp) -> Bool {
        matchesCopyRequirements(other) && createdNano == other.createdNano && modifiedNano == other.modifiedNano
    }

    static func read(_ url: URL, includeExtendedMetadata: Bool = true) throws -> CopyFileStamp {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posixCopyError(url.path) }
        let kind = info.st_mode & mode_t(S_IFMT)
        guard [mode_t(S_IFREG), mode_t(S_IFDIR), mode_t(S_IFLNK)].contains(kind) else {
            throw BackupError.message("不支持的特殊文件：\(url.path)")
        }
        let length = includeExtendedMetadata ? listxattr(url.path, nil, 0, XATTR_NOFOLLOW) : 0
        guard length >= 0 else { throw posixCopyError(url.path) }
        var attributes: [String: String] = [:]
        if length > 0 {
            var names = [CChar](repeating: 0, count: length)
            let count = listxattr(url.path, &names, length, XATTR_NOFOLLOW)
            guard count >= 0 else { throw posixCopyError(url.path) }
            let data = Data(names.prefix(count).map { UInt8(bitPattern: $0) })
            for bytes in data.split(separator: 0) {
                let name = String(decoding: bytes, as: UTF8.self)
                let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
                guard size >= 0 else { throw posixCopyError(url.path) }
                var value = Data(count: size)
                let read = value.withUnsafeMutableBytes { buffer in
                    getxattr(url.path, name, buffer.baseAddress, size, 0, XATTR_NOFOLLOW)
                }
                guard read == size else { throw BackupError.message("读取扩展属性时文件发生变化：\(url.path)") }
                attributes[name] = SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
            }
        }
        var aclText = ""
        if includeExtendedMetadata && kind != mode_t(S_IFLNK) {
            errno = 0
            if let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                var count = 0
                guard let text = acl_to_text(acl, &count) else { throw posixCopyError(url.path) }
                defer { acl_free(text) }
                aclText = String(cString: text)
            } else if errno != 0 && errno != ENOENT && errno != ENOTSUP {
                throw posixCopyError(url.path)
            }
        }
        return CopyFileStamp(kind: kind, size: kind == mode_t(S_IFREG) ? Int64(info.st_size) : 0,
            modified: Int64(info.st_mtimespec.tv_sec), modifiedNano: Int64(info.st_mtimespec.tv_nsec),
            created: Int64(info.st_birthtimespec.tv_sec), createdNano: Int64(info.st_birthtimespec.tv_nsec),
            mode: info.st_mode & 0o7777, uid: info.st_uid, gid: info.st_gid, flags: info.st_flags,
            attributes: attributes, acl: aclText,
            link: kind == mode_t(S_IFLNK) ? try FileManager.default.destinationOfSymbolicLink(atPath: url.path) : nil)
    }
}

func posixCopyError(_ path: String) -> Error {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
}

func copyFilenameMatches(_ target: URL, sourceName: String) -> Bool {
    // Query the stored name, rather than merely echoing the requested URL spelling.
    guard let name = try? target.resourceValues(forKeys: [.nameKey]).name else { return false }
    return name == sourceName
}

struct DirectoryCopyProgress: Sendable {
    var scanning = true
    var scanned = 0
    var total = 0
    var done = 0
    var copied = 0
    var skipped = 0
    var failed = 0
    var bytes: Int64 = 0
    var totalBytes: Int64 = 0
    var resumedBytes: Int64 = 0
    var archivedExtras = 0
    var elapsed: Double = 0
    var text = "请选择源目录和目标目录。"
    var remaining: Double? {
        let transferred = bytes - resumedBytes
        guard !scanning, transferred > 0, elapsed > 1, bytes < totalBytes else { return nil }
        return Double(totalBytes - bytes) / (Double(transferred) / elapsed)
    }
}

private struct CopyEntry {
    let relative: String
    let stamp: CopyFileStamp
}
private struct CopyCheckpoint: Codable {
    let source: String
    let destination: String
    let relative: String
    let stamp: CopyFileStamp
}

final class DirectoryCopyEngine {
    let source: URL
    let destination: URL
    let includeHidden: Bool
    let keepExtras: Bool
    let quickCheck: Bool
    let cancellation: CopyCancellation
    private let fm = FileManager.default

    private func skipDirectory(_ url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posixCopyError(url.path) }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { return false }
        return url.lastPathComponent.hasPrefix(".directory-copy-") ||
            (!includeHidden && (url.lastPathComponent.hasPrefix(".") || (info.st_flags & UInt32(UF_HIDDEN)) != 0))
    }

    init(source: URL, destination: URL, includeHidden: Bool, keepExtras: Bool = true, quickCheck: Bool = true, cancellation: CopyCancellation) throws {
        func canonical(_ url: URL) throws -> URL {
            guard let path = Darwin.realpath(url.path, nil) else { throw posixCopyError(url.path) }
            defer { free(path) }
            return URL(fileURLWithPath: String(cString: path), isDirectory: false)
        }
        self.source = try canonical(source)
        self.destination = try canonical(destination)
        self.includeHidden = includeHidden; self.keepExtras = keepExtras; self.cancellation = cancellation
        self.quickCheck = quickCheck
        let a = self.source.path, b = self.destination.path
        guard a != b, a != "/", b != "/", !a.hasPrefix(b + "/"), !b.hasPrefix(a + "/") else {
            throw BackupError.message("源目录和目标目录不能相同，也不能相互包含。")
        }
        for folder in [self.source, self.destination] {
            guard try CopyFileStamp.read(folder, includeExtendedMetadata: false).kind == mode_t(S_IFDIR) else {
                throw BackupError.message("请选择已连接且存在的目录：\(folder.path)")
            }
        }
    }

    private func protectParents(_ relative: String) throws {
        var current = destination
        for part in relative.split(separator: "/").dropLast() {
            current.appendPathComponent(String(part))
            let stamp = try CopyFileStamp.read(current, includeExtendedMetadata: false)
            guard stamp.kind == mode_t(S_IFDIR) else {
                throw BackupError.message("目标父路径不是实际目录，未穿过符号链接写入：\(current.path)")
            }
        }
    }

    // Compare direct regular files only; every child directory is checked independently.
    // Bulk URL properties avoid the per-file timestamp and stored-name queries on SMB.
    private func quickMatch(_ folder: URL, target: URL) throws -> Int? {
        var parent = destination
        let relative = String(target.path.dropFirst(destination.path.count)).split(separator: "/")
        for part in relative {
            parent.appendPathComponent(String(part))
            guard let stamp = try? CopyFileStamp.read(parent, includeExtendedMetadata: false), stamp.kind == mode_t(S_IFDIR) else { return nil }
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        func summary(_ url: URL) throws -> (Int, Int64, Set<String>)? {
            let children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))
            var count = 0; var bytes: Int64 = 0; var names = Set<String>()
            for child in children {
                if cancellation.cancelled { return nil }
                let info = try child.resourceValues(forKeys: keys)
                if info.isSymbolicLink == true { return nil }
                if info.isDirectory == true { continue }
                guard info.isRegularFile == true, let size = info.fileSize else { return nil }
                let sum = bytes.addingReportingOverflow(Int64(size))
                guard !sum.overflow else { return nil }
                count += 1; bytes = sum.partialValue; names.insert(child.lastPathComponent)
            }
            return (count, bytes, names)
        }
        guard let a = try summary(folder), let b = try? summary(target), a.0 == b.0, a.1 == b.1 else { return nil }
        // Before archiving target-only files, a rename must trigger a real copy.
        if !keepExtras && a.2 != b.2 { return nil }
        return a.0
    }

    private func metadata(from: URL, to: URL, expected: CopyFileStamp, log: (String) -> Void) throws {
        // Symlinks are copied as links; neither endpoint is followed.
        if copyfile(from.path, to.path, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)) != 0 {
            log("其他属性保留提示（不影响四项检查）：\(posixCopyError(to.path).localizedDescription)")
        }
        // Set the two required timestamps independently of optional metadata support.
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME | ATTR_CMN_MODTIME)
        struct Times { var created: timespec; var modified: timespec }
        var times = Times(created: timespec(tv_sec: Int(expected.created), tv_nsec: Int(expected.createdNano)),
                          modified: timespec(tv_sec: Int(expected.modified), tv_nsec: Int(expected.modifiedNano)))
        _ = setattrlist(to.path, &attributes, &times, MemoryLayout<Times>.size, UInt32(FSOPT_NOFOLLOW))
        let actual = try CopyFileStamp.read(to, includeExtendedMetadata: false)
        guard actual.created == expected.created, actual.modified == expected.modified else {
            throw BackupError.message("时间未保留（秒）：创建时间 源=\(expected.created)、目标=\(actual.created)；修改时间 源=\(expected.modified)、目标=\(actual.modified)")
        }
    }

    func run(update: (DirectoryCopyProgress) -> Void, log: (String) -> Void) throws -> DirectoryCopyProgress {
        var state = DirectoryCopyProgress()
        var lastUpdate = Date.distantPast
        func emit(_ force: Bool = false) {
            if force || Date().timeIntervalSince(lastUpdate) > 0.15 { update(state); lastUpdate = Date() }
        }
        let rootStamp = try CopyFileStamp.read(source, includeExtendedMetadata: false)
        var entries: [CopyEntry] = []
        var directories: [CopyEntry] = []
        var originalPaths = Set<String>()
        var scanError: Error?
        var quickDirectories: [String: Bool] = [:]
        var quickSkipped = 0
        state.text = "正在检查源、目标差异…"; emit(true)
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isHiddenKey, .isRegularFileKey, .isSymbolicLinkKey], options: [],
            errorHandler: { _, error in scanError = error; return false }) else {
            throw BackupError.message("无法读取源目录。")
        }
        for case let url as URL in enumerator {
            if cancellation.cancelled { state.text = "已停止差异检查。"; emit(true); return state }
            guard url.path.hasPrefix(source.path + "/") else {
                throw BackupError.message("目录枚举路径不在源目录中：\(url.path)，源目录：\(source.path)")
            }
            let relative = String(url.path.dropFirst(source.path.count + 1))
            if quickCheck {
                let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if info.isRegularFile == true && info.isSymbolicLink != true {
                    let folder = url.deletingLastPathComponent()
                    if quickDirectories[folder.path] == nil {
                        let folderRelative = String(folder.path.dropFirst(source.path.count))
                        let target = folderRelative.isEmpty ? destination : destination.appendingPathComponent(String(folderRelative.dropFirst()))
                        quickDirectories[folder.path] = try quickMatch(folder, target: target) != nil
                        if quickDirectories[folder.path] == true { log("快速检查通过，跳过目录直属文件：\(folderRelative.isEmpty ? "." : String(folderRelative.dropFirst()))") }
                    }
                    if quickDirectories[folder.path] == true {
                        originalPaths.insert(relative); state.scanned += 1; state.skipped += 1; quickSkipped += 1
                        state.text = "快速检查：已跳过 \(quickSkipped) 个文件，需更新 \(entries.count) 个文件"; emit()
                        continue
                    }
                }
            }
            if try skipDirectory(url) { enumerator.skipDescendants(); continue }
            originalPaths.insert(relative)
            let stamp = try CopyFileStamp.read(url, includeExtendedMetadata: false)
            let entry = CopyEntry(relative: relative, stamp: stamp)
            state.scanned += 1
            if stamp.kind == mode_t(S_IFDIR) {
                directories.append(entry)
            } else {
                let target = destination.appendingPathComponent(relative)
                // Check every ancestor without following symlinks, even on the first run.
                var parent = destination
                var unsafe = false
                for part in relative.split(separator: "/").dropLast() {
                    parent.appendPathComponent(String(part))
                    var info = stat()
                    if lstat(parent.path, &info) == 0 && (info.st_mode & mode_t(S_IFMT)) != mode_t(S_IFDIR) { unsafe = true; break }
                }
                if unsafe { throw BackupError.message("目标包含文件或符号链接形式的父目录：\(relative)") }
                if let existing = try? CopyFileStamp.read(target, includeExtendedMetadata: false),
                   existing.matchesCopyRequirements(stamp), copyFilenameMatches(target, sourceName: url.lastPathComponent) { state.skipped += 1 }
                else { entries.append(entry); state.totalBytes += stamp.size }
            }
            state.text = "正在检查差异：已检查 \(state.scanned) 项，需更新 \(entries.count) 个文件"
            emit()
        }
        if let error = scanError { throw error }
        state.scanning = false; state.total = entries.count
        let start = Date()
        let identity = digest(source.path + "\n" + destination.path)
        let work = destination.appendingPathComponent(".directory-copy-" + String(identity.prefix(16)), isDirectory: true)
        let marker = work.appendingPathComponent("identity.txt")
        var existingDir: ObjCBool = false
        if fm.fileExists(atPath: work.path, isDirectory: &existingDir) {
            guard existingDir.boolValue, try CopyFileStamp.read(work, includeExtendedMetadata: false).kind == mode_t(S_IFDIR),
                  try String(contentsOf: marker, encoding: .utf8) == identity else {
                throw BackupError.message("目标中的临时目录不属于本任务，未改动其内容。")
            }
        } else {
            try fm.createDirectory(at: work, withIntermediateDirectories: false)
            try identity.write(to: marker, atomically: true, encoding: .utf8)
        }
        let lock = Darwin.open(work.appendingPathComponent("task.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw posixCopyError(work.path) }
        defer { flock(lock, LOCK_UN); Darwin.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw BackupError.message("此源和目标之间已有复制任务。") }
        for directory in directories {
            if cancellation.cancelled { state.text = "已停止，已完成内容保留。"; emit(true); return state }
            try protectParents(directory.relative)
            let target = destination.appendingPathComponent(directory.relative)
            if fm.fileExists(atPath: target.path) {
                guard try CopyFileStamp.read(target, includeExtendedMetadata: false).kind == mode_t(S_IFDIR) else {
                    throw BackupError.message("目标同名项不是目录，未删除已有内容：\(directory.relative)")
                }
            } else { try fm.createDirectory(at: target, withIntermediateDirectories: false) }
        }
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "正在复制目录")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        for entry in entries {
            if cancellation.cancelled { break }
            let input = source.appendingPathComponent(entry.relative)
            let output = destination.appendingPathComponent(entry.relative)
            let name = digest(entry.relative)
            let partial = work.appendingPathComponent(name + ".partial")
            let receiptURL = work.appendingPathComponent(name + ".json")
            state.text = "正在复制：\(entry.relative)"; emit(true)
            do {
                try protectParents(entry.relative)
                guard try CopyFileStamp.read(input, includeExtendedMetadata: false).sameSourceVersion(entry.stamp) else {
                    throw BackupError.message("检查后源文件发生变化，请下次重试：\(entry.relative)")
                }
                if let existing = try? CopyFileStamp.read(output, includeExtendedMetadata: false), existing.kind == mode_t(S_IFDIR) {
                    throw BackupError.message("目标同名项为目录，未删除：\(entry.relative)")
                }
                if entry.stamp.kind == mode_t(S_IFREG) {
                    let checkpoint = CopyCheckpoint(source: source.path, destination: destination.path,
                        relative: entry.relative, stamp: entry.stamp)
                    var offset: Int64 = 0
                    if let oldData = try? Data(contentsOf: receiptURL),
                       let old = try? JSONDecoder().decode(CopyCheckpoint.self, from: oldData),
                       old.source == source.path, old.destination == destination.path,
                       old.relative == entry.relative, old.stamp.sameSourceVersion(entry.stamp),
                       let size = try? fileSize(partial), size <= entry.stamp.size { offset = size }
                    else {
                        if (try? CopyFileStamp.read(partial, includeExtendedMetadata: false)) != nil { try fm.removeItem(at: partial) }
                        let fd = Darwin.open(partial.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
                        guard fd >= 0 else { throw posixCopyError(partial.path) }
                        Darwin.close(fd)
                        try JSONEncoder().encode(checkpoint).write(to: receiptURL, options: .atomic)
                    }
                    _ = chflags(partial.path, 0); _ = chmod(partial.path, 0o600)
                    let reader = try FileHandle(forReadingFrom: input)
                    let writer = try FileHandle(forWritingTo: partial)
                    defer { try? reader.close(); try? writer.close() }
                    // Validate an interrupted prefix before reusing it. No bytes are retransferred.
                    if offset > 0 {
                        let previous = try FileHandle(forReadingFrom: partial)
                        defer { try? previous.close() }
                        var checked: Int64 = 0
                        while checked < offset {
                            if cancellation.cancelled { break }
                            let amount = Int(min(8 * 1024 * 1024, offset - checked))
                            let a = try reader.read(upToCount: amount) ?? Data()
                            let b = try previous.read(upToCount: amount) ?? Data()
                            if a.count != amount || a != b {
                                try writer.truncate(atOffset: 0); offset = 0
                                log("\(entry.relative)：未完成片段校验不符，仅重新复制此文件，其他已完成文件保留。")
                                break
                            }
                            checked += Int64(amount)
                        }
                        if cancellation.cancelled { break }
                        state.resumedBytes += offset; state.bytes += offset
                    }
                    try reader.seek(toOffset: UInt64(offset)); try writer.seek(toOffset: UInt64(offset))
                    var sinceSync: Int64 = 0
                    while offset < entry.stamp.size && !cancellation.cancelled {
                        let amount = Int(min(8 * 1024 * 1024, entry.stamp.size - offset))
                        let data = try reader.read(upToCount: amount) ?? Data()
                        guard !data.isEmpty else { throw BackupError.message("源文件读取提前结束：\(entry.relative)") }
                        try writer.write(contentsOf: data)
                        offset += Int64(data.count); sinceSync += Int64(data.count); state.bytes += Int64(data.count)
                        if sinceSync >= 32 * 1024 * 1024 { try writer.synchronize(); sinceSync = 0 }
                        state.elapsed = Date().timeIntervalSince(start); emit(offset == Int64(data.count))
                    }
                    try writer.synchronize()
                    if cancellation.cancelled { break }
                    guard try CopyFileStamp.read(input, includeExtendedMetadata: false).sameSourceVersion(entry.stamp) else {
                        throw BackupError.message("复制期间源文件发生变化，未替换目标：\(entry.relative)")
                    }
                } else {
                    if fm.fileExists(atPath: partial.path) || (try? CopyFileStamp.read(partial, includeExtendedMetadata: false)) != nil { try fm.removeItem(at: partial) }
                    try fm.createSymbolicLink(atPath: partial.path, withDestinationPath: entry.stamp.link!)
                }
                try metadata(from: input, to: partial, expected: entry.stamp, log: log)
                // Clear temporary immutable flags for rename; restore them on the final object.
                if entry.stamp.kind != mode_t(S_IFLNK), entry.stamp.flags != 0 {
                    _ = chflags(partial.path, 0)
                }
                guard rename(partial.path, output.path) == 0 else { throw posixCopyError(output.path) }
                if entry.stamp.kind != mode_t(S_IFLNK), entry.stamp.flags != 0 {
                    _ = chflags(output.path, entry.stamp.flags)
                }
                let completed = try CopyFileStamp.read(output, includeExtendedMetadata: false)
                guard completed.matchesCopyRequirements(entry.stamp), copyFilenameMatches(output, sourceName: input.lastPathComponent) else {
                    throw BackupError.message("文件检查不一致：\(entry.relative)；大小 源=\(entry.stamp.size)、目标=\(completed.size)；创建秒 源=\(entry.stamp.created)、目标=\(completed.created)；修改秒 源=\(entry.stamp.modified)、目标=\(completed.modified)；请同时检查文件名及类型")
                }
                if fm.fileExists(atPath: receiptURL.path) { try fm.removeItem(at: receiptURL) }
                state.copied += 1
            } catch {
                state.failed += 1; log("\(entry.relative)：\(error.localizedDescription)")
            }
            state.done += 1; state.elapsed = Date().timeIntervalSince(start); emit(true)
        }
        if !cancellation.cancelled {
            func applyDirectoryMetadata() {
                for directory in directories.reversed() {
                    if cancellation.cancelled { break }
                    do {
                        let input = source.appendingPathComponent(directory.relative)
                        let target = destination.appendingPathComponent(directory.relative)
                        try metadata(from: input, to: target, expected: directory.stamp, log: log)
                        guard try CopyFileStamp.read(target, includeExtendedMetadata: false).matchesCopyRequirements(directory.stamp) else {
                            throw BackupError.message("目标目录创建时间或修改时间未能保留到秒。")
                        }
                    } catch { state.failed += 1; log("目录 \(directory.relative)：\(error.localizedDescription)") }
                }
            }
            applyDirectoryMetadata()
            if !keepExtras && state.failed == 0 {
                // Include files that were skipped after metadata comparison as well.
                var currentPaths = Set<String>()
                var enumerationError: Error?
                let fresh = fm.enumerator(at: source, includingPropertiesForKeys: [.isHiddenKey], options: [],
                    errorHandler: { _, error in enumerationError = error; return false })!
                for case let url as URL in fresh {
                    if cancellation.cancelled { break }
                    if try skipDirectory(url) { fresh.skipDescendants(); continue }
                    currentPaths.insert(String(url.path.dropFirst(source.path.count + 1)))
                }
                if let error = enumerationError { state.failed += 1; log("未处理目标独有项：\(error.localizedDescription)") }
                else if !cancellation.cancelled {
                    // Every originally pending path must still exist before any cleanup.
                    if originalPaths != currentPaths {
                        state.failed += 1; log("源目录结构发生变化，本次不处理目标独有项。")
                    } else {
                        do { state.archivedExtras = try archiveExtras(sourcePaths: currentPaths, log: log) }
                        catch { state.failed += 1; log("目标独有项归档未完成：\(error.localizedDescription)") }
                    }
                }
            }
            // Removing extras changes parent timestamps; restore them after archival as well.
            if state.archivedExtras > 0 { applyDirectoryMetadata() }
            if state.failed == 0 && !cancellation.cancelled {
                // Only our marker and lock remain. Never recursively remove a workspace.
                let contents = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                if contents.allSatisfy({ ["identity.txt", "task.lock"].contains($0.lastPathComponent) }) {
                    for file in contents { try fm.removeItem(at: file) }
                    try fm.removeItem(at: work)
                }
                do {
                    try metadata(from: source, to: destination, expected: rootStamp, log: log)
                    guard try CopyFileStamp.read(destination, includeExtendedMetadata: false).matchesCopyRequirements(rootStamp) else { throw BackupError.message("目标根目录创建时间或修改时间未能保留到秒。") }
                } catch { state.failed += 1; log("根目录：\(error.localizedDescription)") }
            }
        }
        state.text = cancellation.cancelled ? "已停止；再次开始会检查差异并续传未完成文件。" :
            (state.failed == 0 ? "目录复制完成。" : "复制结束，有 \(state.failed) 项失败，请查看大小或秒级时间的具体差异。")
        state.elapsed = Date().timeIntervalSince(start); emit(true)
        return state
    }

    private func archiveExtras(sourcePaths: Set<String>, log: (String) -> Void) throws -> Int {
        var extras: [String] = []
        var enumerationError: Error?
        guard let scan = fm.enumerator(at: destination, includingPropertiesForKeys: [.isHiddenKey], options: [],
            errorHandler: { _, error in enumerationError = error; return false }) else { throw BackupError.message("无法检查目标独有项。") }
        for case let url as URL in scan {
            if cancellation.cancelled { return 0 }
            if try skipDirectory(url) { scan.skipDescendants(); continue }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw posixCopyError(url.path) }
            let relative = String(url.path.dropFirst(destination.path.count + 1))
            if !sourcePaths.contains(relative) {
                extras.append(relative)
                if (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) { scan.skipDescendants() }
            }
        }
        if let error = enumerationError { throw error }
        guard !extras.isEmpty else { return 0 }
        let archiveRoot = destination.appendingPathComponent(".directory-copy-archive", isDirectory: true)
        if fm.fileExists(atPath: archiveRoot.path) {
            guard try CopyFileStamp.read(archiveRoot, includeExtendedMetadata: false).kind == mode_t(S_IFDIR) else { throw BackupError.message("归档位置不是实际目录。") }
        }
        let batch = archiveRoot.appendingPathComponent((BackupLayout.dateText(Date(), "yyyyMMdd_HHmmss") ?? "batch") + "_" + UUID().uuidString)
        try fm.createDirectory(at: batch, withIntermediateDirectories: true)
        try JSONEncoder().encode(extras).write(to: batch.appendingPathComponent("manifest.json"), options: .atomic)
        let payload = batch.appendingPathComponent("files", isDirectory: true)
        var archived = 0
        for relative in extras {
            if cancellation.cancelled { break }
            // Do not archive a source item created since the scan.
            if (try? CopyFileStamp.read(source.appendingPathComponent(relative), includeExtendedMetadata: false)) != nil { continue }
            try protectParents(relative)
            let target = payload.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: destination.appendingPathComponent(relative), to: target)
            archived += 1
        }
        log("目标独有项已归档 \(archived) 项，可从 \(batch.path)/files 恢复。")
        return archived
    }
}
