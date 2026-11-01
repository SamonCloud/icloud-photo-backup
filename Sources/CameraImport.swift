import Foundation
import Darwin
import CryptoKit
import ImageIO
import AVFoundation

enum CameraMedia {
    static let raw: Set<String> = ["arw", "sr2", "srf", "dng", "cr2", "cr3", "crw", "nef", "nrw", "raf", "orf", "rw2", "rwl", "pef", "ptx", "srw", "raw", "3fr", "fff", "iiq", "mos", "mef", "kdc", "dcr", "erf", "mrw", "x3f"]
    static let images: Set<String> = ["jpg", "jpeg", "jpe", "heic", "heif", "hif", "avif", "tif", "tiff", "png", "bmp", "gif", "webp"]
    static let videos: Set<String> = ["mp4", "mov", "m4v", "mts", "m2ts", "avi", "mpg", "mpeg", "mxf", "3gp", "3g2", "mkv", "webm", "vob", "mod", "tod"]
    static func accepts(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return raw.contains(ext) || images.contains(ext) || videos.contains(ext)
    }
    static func captureDate(_ url: URL) throws -> Date {
        if !videos.contains(url.pathExtension.lowercased()),
           let image = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any] {
            let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
            let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
            if let text = exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String ?? tiff?[kCGImagePropertyTIFFDateTime as String] as? String {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = .current; formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"; formatter.isLenient = false
                if let date = formatter.date(from: text) { return date }
            }
        }
        if videos.contains(url.pathExtension.lowercased()) {
            let asset = AVURLAsset(url: url)
            // Legacy camera movie headers may contain local wall-clock seconds labelled
            // as UTC. Prefer an explicit textual creation date; otherwise use file time.
            let items = asset.commonMetadata.filter { $0.commonKey == .commonKeyCreationDate } + [asset.creationDate].compactMap { $0 }
            for item in items {
                guard let text = item.stringValue else { continue }
                let iso = ISO8601DateFormatter()
                if let date = iso.date(from: text) { return date }
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = iso.date(from: text) { return date }
            }
        }
        let stamp = try CopyFileStamp.read(url, includeExtendedMetadata: false)
        return Date(timeIntervalSince1970: TimeInterval(stamp.modified))
    }
}

struct CameraDateRule {
    let pattern: String
    init(_ text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 100, !text.contains("/"), !text.contains(":"), !text.contains("\\"), !text.hasPrefix("."),
              !text.contains("\n"), !text.contains("\r"), !text.contains("\0") else { throw BackupError.message("日期命名规则不能包含路径分隔符、换行或以点开头，且长度不能超过 100 字节。") }
        let normalized = text.replacingOccurrences(of: "yyyy", with: "yyyy", options: .caseInsensitive)
            .replacingOccurrences(of: "mm", with: "MM", options: .caseInsensitive)
            .replacingOccurrences(of: "dd", with: "dd", options: .caseInsensitive)
        guard normalized.contains("yyyy"), normalized.contains("MM"), normalized.contains("dd") else {
            throw BackupError.message("命名规则需要包含 yyyy、mm 和 dd，例如 yyyymmdd 或 yyyy-mm-dd_旅行。")
        }
        pattern = normalized
    }
    private func render(_ pattern: String, _ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return pattern.replacingOccurrences(of: "yyyy", with: String(format: "%04d", parts.year!))
            .replacingOccurrences(of: "MM", with: String(format: "%02d", parts.month!))
            .replacingOccurrences(of: "dd", with: String(format: "%02d", parts.day!))
    }
    func name(_ date: Date) -> String { render(pattern, date) }
    func prefixes(_ date: Date) -> [String] {
        let ends = ["yyyy", "MM", "dd"].compactMap { pattern.range(of: $0, options: .backwards)?.upperBound }
        let end = ends.max()!
        return [render(String(pattern[..<end]), date), render("yyyyMMdd", date)]
    }
}

enum CameraConflictChoice { case importFiles, skip, skipAll, cancel }
struct CameraReceipt: Codable {
    let key: String
    let relative: String
    let bytes: Int64
    let sha256: String
    let captured: Date
    let original: String
}

final class CameraImportEngine {
    let source: URL, destination: URL
    let rule: CameraDateRule
    let onlyNew: Bool
    let cancellation: CopyCancellation
    private let fm = FileManager.default
    private let dateReader: (URL) throws -> Date
    init(source: URL, destination: URL, pattern: String, onlyNew: Bool, cancellation: CopyCancellation,
         dateReader: @escaping (URL) throws -> Date = CameraMedia.captureDate) throws {
        self.source = source.resolvingSymlinksInPath().standardizedFileURL
        self.destination = destination.resolvingSymlinksInPath().standardizedFileURL
        self.rule = try CameraDateRule(pattern); self.onlyNew = onlyNew; self.cancellation = cancellation; self.dateReader = dateReader
        let a = self.source.path, b = self.destination.path
        guard a != "/", a != b, !a.hasPrefix(b + "/"), !b.hasPrefix(a + "/") else { throw BackupError.message("存储卡和导入目标不能相同或相互包含。") }
        for folder in [self.source, self.destination] {
            guard try CopyFileStamp.read(folder, includeExtendedMetadata: false).kind == mode_t(S_IFDIR) else { throw BackupError.message("请选择存在且已连接的目录。") }
        }
    }
    private func ensureDirectory(_ relative: String) throws -> URL {
        var current = destination
        for part in relative.split(separator: "/") {
            guard part != ".", part != ".." else { throw BackupError.message("导入路径无效。") }
            current.appendPathComponent(String(part))
            var info = stat()
            if lstat(current.path, &info) == 0 {
                guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { throw BackupError.message("目标路径不是实际目录，未穿过符号链接：\(current.lastPathComponent)") }
            } else {
                guard errno == ENOENT else { throw posixCopyError(current.path) }
                try fm.createDirectory(at: current, withIntermediateDirectories: false)
            }
        }
        return current
    }
    private func existingDirectoryNames() throws -> [String] {
        try fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).compactMap {
            let info = try $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return info.isDirectory == true && info.isSymbolicLink != true ? $0.lastPathComponent : nil
        }
    }
    func run(update: (DirectoryCopyProgress) -> Void, log: (String) -> Void,
             conflict: (String, [String]) -> CameraConflictChoice) throws -> DirectoryCopyProgress {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "正在导入相机照片和视频")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        var state = DirectoryCopyProgress(); var lastUpdate = Date.distantPast
        let started = Date()
        func emit(_ force: Bool = false) {
            state.elapsed = Date().timeIntervalSince(started)
            if force || Date().timeIntervalSince(lastUpdate) > 0.2 { update(state); lastUpdate = Date() }
        }
        let meta = try ensureDirectory(".camera-import")
        let lockURL = meta.appendingPathComponent("task.lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posixCopyError(lockURL.path) }
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw BackupError.message("目标中已有相机导入任务。") }
        let volume = try source.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString ?? source.path
        let journalURL = meta.appendingPathComponent(String(digest(volume).prefix(24)) + ".jsonl")
        if fm.fileExists(atPath: journalURL.path), try CopyFileStamp.read(journalURL, includeExtendedMetadata: false).kind != mode_t(S_IFREG) { throw BackupError.message("导入记录不是普通文件。") }
        var receipts: [String: CameraReceipt] = [:]
        if let data = try? Data(contentsOf: journalURL) {
            for line in data.split(separator: 10) {
                if let record = try? JSONDecoder().decode(CameraReceipt.self, from: Data(line)) { receipts[record.key] = record }
            }
        }
        let journalFD = Darwin.open(journalURL.path, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW, 0o600)
        guard journalFD >= 0 else { throw posixCopyError(journalURL.path) }
        let journal = FileHandle(fileDescriptor: journalFD, closeOnDealloc: true)
        defer { try? journal.close() }
        let excludedURL = meta.appendingPathComponent("excluded-dates.json")
        var excludedDates = Set<String>()
        if fm.fileExists(atPath: excludedURL.path) {
            guard try CopyFileStamp.read(excludedURL, includeExtendedMetadata: false).kind == mode_t(S_IFREG) else { throw BackupError.message("日期排除记录不是普通文件。") }
            excludedDates = try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: excludedURL))
        }
        let dayRule = try CameraDateRule("yyyymmdd")
        if onlyNew {
            // Import history survives deleting a date folder. Recognize renamed,
            // date-prefixed folders too, so a rename is not treated as deletion.
            let existing = try existingDirectoryNames()
            var priorDates: [String: (Date, Set<String>)] = [:]
            for file in try fm.contentsOfDirectory(at: meta, includingPropertiesForKeys: nil) where file.pathExtension == "jsonl" {
                guard try CopyFileStamp.read(file, includeExtendedMetadata: false).kind == mode_t(S_IFREG) else { continue }
                for line in try Data(contentsOf: file).split(separator: 10) {
                    guard let record = try? JSONDecoder().decode(CameraReceipt.self, from: Data(line)),
                          let folder = record.relative.split(separator: "/").first else { continue }
                    let day = dayRule.name(record.captured)
                    var value = priorDates[day] ?? (record.captured, Set<String>())
                    value.1.insert(String(folder)); priorDates[day] = value
                }
            }
            for (day, prior) in priorDates {
                let prefixes = rule.prefixes(prior.0)
                if !existing.contains(where: { name in prior.1.contains(name) || prefixes.contains(where: { name.hasPrefix($0) }) }) {
                    excludedDates.insert(day)
                }
            }
            try JSONEncoder().encode(excludedDates).write(to: excludedURL, options: .atomic)
            if !excludedDates.isEmpty { log("已记住 \(excludedDates.count) 个删除过导入目录的日期，本次跳过这些日期中已成功导入过的旧文件，新拍摄文件仍会导入。") }
        }
        let lastURL = meta.appendingPathComponent("last-import.json")
        var latest = (try? Data(contentsOf: lastURL)).flatMap { try? JSONDecoder().decode(CameraReceipt.self, from: $0) }
        func append(_ record: CameraReceipt) throws {
            var data = Data([10]); data.append(try JSONEncoder().encode(record)); data.append(10)
            try journal.write(contentsOf: data); try journal.synchronize(); receipts[record.key] = record
        }
        struct Entry { let url: URL; let stamp: CopyFileStamp; let date: Date; let folder: String; let key: String }
        var groups: [String: [Entry]] = [:]; var enumerationError: Error?
        state.text = "正在遍历存储卡，读取拍摄日期…"; emit(true)
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw BackupError.message("无法遍历存储卡。") }
        for case let url as URL in enumerator {
            if cancellation.cancelled { break }
            try autoreleasepool {
                let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if info.isSymbolicLink == true { return }
                if info.isDirectory == true && [".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems"].contains(url.lastPathComponent) { enumerator.skipDescendants(); return }
                if url.lastPathComponent.hasPrefix("._") { return }
                guard info.isDirectory != true, CameraMedia.accepts(url) else { return }
                state.scanned += 1
                do {
                    let stamp = try CopyFileStamp.read(url, includeExtendedMetadata: false)
                    guard stamp.kind == mode_t(S_IFREG) else { return }
                    let date = try dateReader(url)
                    let relative = String(url.path.dropFirst(source.path.count + 1))
                    let key = digest("\(relative)\n\(stamp.size)\n\(stamp.modified).\(stamp.modifiedNano)\n\(date.timeIntervalSince1970)")
                    if onlyNew && excludedDates.contains(dayRule.name(date)) && receipts[key] != nil { state.skipped += 1; return }
                    if onlyNew, let record = receipts[key], !record.relative.hasPrefix("/"), !record.relative.split(separator: "/").contains("..") {
                        // Validate ancestors without creating them or following a link.
                        var current = destination; var safe = true
                        for part in record.relative.split(separator: "/").dropLast() {
                            current.appendPathComponent(String(part))
                            if (try? CopyFileStamp.read(current, includeExtendedMetadata: false).kind) != mode_t(S_IFDIR) { safe = false; break }
                        }
                        if safe, let actual = try? CopyFileStamp.read(destination.appendingPathComponent(record.relative), includeExtendedMetadata: false), actual.kind == mode_t(S_IFREG), actual.size == record.bytes { state.skipped += 1; return }
                    }
                    let folder = rule.name(date)
                    groups[folder, default: []].append(Entry(url: url, stamp: stamp, date: date, folder: folder, key: key))
                    state.total += 1; state.totalBytes += stamp.size
                } catch { state.failed += 1; log("读取失败 \(url.lastPathComponent)：\(error.localizedDescription)") }
                emit()
            }
        }
        if let error = enumerationError { throw error }
        state.scanning = false; emit(true)
        var skipAll = false
        for folder in groups.keys.sorted() {
            if cancellation.cancelled { break }
            let entries = groups[folder]!.sorted { $0.date == $1.date ? $0.url.path < $1.url.path : $0.date < $1.date }
            let names = try existingDirectoryNames().filter { name in rule.prefixes(entries[0].date).contains { name.hasPrefix($0) } }.sorted()
            if !names.isEmpty {
                let choice = skipAll ? CameraConflictChoice.skip : conflict(folder, names)
                if choice == .cancel { cancellation.cancel(); break }
                if choice == .skipAll { skipAll = true }
                if choice == .skip || choice == .skipAll {
                    state.skipped += entries.count; state.done += entries.count
                    state.totalBytes -= entries.reduce(Int64(0)) { $0 + $1.stamp.size }
                    log("跳过日期目录 \(folder)，未记录为已导入，下次仍可选择导入。"); emit(true); continue
                }
            }
            for entry in entries {
                if cancellation.cancelled { break }
                state.text = "正在导入：\(entry.url.lastPathComponent) → \(folder)"; emit(true)
                autoreleasepool {
                    do {
                        let subfolder = folder + (CameraMedia.raw.contains(entry.url.pathExtension.lowercased()) ? "/RAW" : "")
                        let targetFolder = try ensureDirectory(subfolder)
                        let partial = meta.appendingPathComponent("\(UUID().uuidString).partial")
                        defer { try? fm.removeItem(at: partial) }
                        let tempFD = Darwin.open(partial.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
                        guard tempFD >= 0 else { throw posixCopyError(partial.path) }
                        let writer = FileHandle(fileDescriptor: tempFD, closeOnDealloc: true)
                        let reader = try FileHandle(forReadingFrom: entry.url)
                        defer { try? reader.close(); try? writer.close() }
                        var hasher = SHA256(); var count: Int64 = 0
                        while count < entry.stamp.size && !cancellation.cancelled {
                            let size = try autoreleasepool {
                                let data = try reader.read(upToCount: Int(min(8 * 1024 * 1024, entry.stamp.size - count))) ?? Data()
                                guard !data.isEmpty else { throw BackupError.message("文件读取提前结束。") }
                                try writer.write(contentsOf: data); hasher.update(data: data); return Int64(data.count)
                            }
                            count += size; state.bytes += size; emit(count == size)
                        }
                        try writer.synchronize(); try writer.close()
                        if cancellation.cancelled { return }
                        guard try CopyFileStamp.read(entry.url, includeExtendedMetadata: false).sameSourceVersion(entry.stamp) else { throw BackupError.message("导入期间源文件发生变化，下次重试。") }
                        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                        var output = targetFolder.appendingPathComponent(entry.url.lastPathComponent)
                        var suffix = 1; var identical = false
                        while (try? CopyFileStamp.read(output, includeExtendedMetadata: false)) != nil || fm.fileExists(atPath: output.path) {
                            if let existing = try? CopyFileStamp.read(output, includeExtendedMetadata: false), existing.kind == mode_t(S_IFREG), existing.size == count, try fileHash(output) == hash { identical = true; break }
                            suffix += 1
                            output = targetFolder.appendingPathComponent(entry.url.deletingPathExtension().lastPathComponent + "_\(suffix)." + entry.url.pathExtension)
                        }
                        if identical { state.skipped += 1 }
                        else {
                            // Preserve available metadata; publish only a complete file, never overwrite.
                            if copyfile(entry.url.path, partial.path, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)) != 0 { log("属性保留提示：\(entry.url.lastPathComponent)，目标可能不支持部分属性。") }
                            try fm.moveItem(at: partial, to: output); state.copied += 1
                        }
                        let record = CameraReceipt(key: entry.key, relative: subfolder + "/" + output.lastPathComponent, bytes: count, sha256: hash, captured: entry.date, original: entry.url.lastPathComponent)
                        try append(record)
                        if latest == nil || record.captured >= latest!.captured {
                            try JSONEncoder().encode(record).write(to: lastURL, options: .atomic); latest = record
                        }
                        log("已导入：\(record.relative)")
                    } catch { state.failed += 1; log("导入失败 \(entry.url.lastPathComponent)：\(error.localizedDescription)") }
                }
                state.done += 1; emit(true)
            }
        }
        state.text = cancellation.cancelled ? "相机导入已停止；成功文件已记录，下次只导入未完成文件。" : (state.failed == 0 ? "相机导入完成。" : "相机导入结束，有 \(state.failed) 项失败，可再次重试。")
        emit(true); return state
    }
}
