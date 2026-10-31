import Foundation

enum TaskLogHistory {
    enum Kind { case photo, directory }

    static func directory(_ kind: Kind) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(kind == .photo ? "PhotoIncrementalBackup/Logs" : "PhotoIncrementalBackup/CopyLogs", isDirectory: true)
    }

    static func latest(_ kind: Kind, excluding current: URL? = nil) -> URL? {
        latest(in: directory(kind), excluding: current)
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
