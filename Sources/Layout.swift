import Foundation

enum BackupLayout {
    static let timezone = TimeZone(identifier: "Asia/Shanghai")!
    static func dateText(_ date: Date?, _ format: String) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
    static func safe(_ value: String, maxBytes: Int = 110) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            let character = CharacterSet.controlCharacters.contains(scalar) || "/:\\".unicodeScalars.contains(scalar) ? "_" : String(scalar)
            if result.utf8.count + character.utf8.count > maxBytes { break }
            result += character
        }
        return result.isEmpty || result == "." || result == ".." ? "resource" : result
    }
    static func role(_ type: Int) -> String {
        switch type {
        case 1, 2, 9: return ""
        case 5, 6, 10: return "_edited"
        case 7: return "_adjustment"
        case 8, 11, 12: return "_editbase"
        case 4: return "_alternate"
        case 3: return "_audio"
        default: return "_resource\(type)"
        }
    }
    static func slot(asset: String, type: Int, filename: String) -> String {
        digest("\(asset)|\(type)|\(filename)")
    }
    static func path(date: Date?, baseFilename: String, originalFilename: String,
                     type: Int, token: String, extra: String = "") -> String {
        let folder = dateText(date, "yyyy/MM") ?? "_undated"
        let stamp = dateText(date, "yyyyMMdd_HHmmss") ?? "undated"
        let stem = safe((baseFilename as NSString).deletingPathExtension)
        let ext = safe((originalFilename as NSString).pathExtension, maxBytes: 20)
        let extensionText = (originalFilename as NSString).pathExtension.isEmpty ? "" : ".\(ext)"
        return "\(folder)/\(stamp)_\(stem)_\(token)\(role(type))\(extra)\(extensionText)"
    }
    static func versionPath(_ receipt: Receipt) -> String {
        let file = (receipt.relativePath as NSString).lastPathComponent as NSString
        let folder = dateText(receipt.creationDate, "yyyy/MM") ?? "_undated"
        let version = dateText(receipt.modificationDate ?? receipt.creationDate, "yyyyMMdd_HHmmss") ?? "undated"
        let ext = file.pathExtension.isEmpty ? "" : ".\(file.pathExtension)"
        return "_versions/\(folder)/\(file.deletingPathExtension)_v\(version)_\(receipt.sha256.prefix(12))\(ext)"
    }
    static func addingSuffix(_ suffix: String, to path: String) -> String {
        let value = path as NSString
        let ext = value.pathExtension.isEmpty ? "" : ".\(value.pathExtension)"
        return value.deletingPathExtension + suffix + ext
    }
}

struct PendingMove: Codable {
    let from: String
    let to: String
    let bytes: Int64
    let sha256: String
    let updates: [Receipt]
}
struct LayoutMigration: Codable {
    let schema: Int
    let createdAt: Date
    var completedAt: Date?
    let moves: [PendingMove]
}

extension Receipt {
    var stableSlot: String { BackupLayout.slot(asset: assetIdentifier, type: resourceType, filename: originalFilename) }
    func relocating(to path: String, token: String? = nil) -> Receipt {
        var copy = self
        copy.relativePath = path; copy.assetToken = token ?? assetToken; copy.layoutVersion = 2
        return copy
    }
}
