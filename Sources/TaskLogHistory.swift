import Foundation

struct TaskRunRecord: Codable {
    enum Status: String, Codable { case running, completed, stopped, failed }
    let status: Status
    let text: String
    let logPath: String?
    let updatedAt: Date

    static var copyURL: URL {
        TaskLogHistory.directory(.directory).deletingLastPathComponent().appendingPathComponent("last-copy-task.json")
    }
    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
    static func load(from url: URL) -> TaskRunRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    var restoredMessage: String {
        let heading = status == .running ? "上次目录复制异常中断，未记录完成；可点击“开始 / 继续复制”恢复。" : "上次目录复制结果："
        return "\(heading)\n最后记录：\(updatedAt.formatted())\n\(text)"
    }
}

enum TaskLogHistory {
    enum Kind { case photo, directory, camera }

    static func directory(_ kind: Kind) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(kind == .photo ? "PhotoIncrementalBackup/Logs" : (kind == .camera ? "PhotoIncrementalBackup/CameraLogs" : "PhotoIncrementalBackup/CopyLogs"), isDirectory: true)
    }

    static func latest(_ kind: Kind, excluding current: URL? = nil) -> URL? {
        latest(in: directory(kind), excluding: current)
    }

    static func tail(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: end > 16384 ? end - 16384 : 0)
            return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        } catch { return nil }
    }

    static func latest(in directory: URL, excluding current: URL? = nil) -> URL? {
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return nil }
        let excluded = current?.resolvingSymlinksInPath().standardizedFileURL.path
        return files.compactMap { file -> (URL, Date, Date)? in
            guard file.pathExtension.lowercased() == "txt",
                  file.resolvingSymlinksInPath().standardizedFileURL.path != excluded,
                  let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return (file, values.creationDate ?? values.contentModificationDate ?? .distantPast,
                    values.contentModificationDate ?? .distantPast)
        }.max {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.2 != $1.2 { return $0.2 < $1.2 }
            return $0.0.lastPathComponent < $1.0.lastPathComponent
        }?.0
    }
}
