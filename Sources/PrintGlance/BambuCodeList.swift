import Foundation

/// Reads Bambu's own descriptions of printer codes from the lists Bambu Studio keeps on this Mac, the ones its
/// Device tab shows: about 8,000 codes across Bambu's printers. Nothing is fetched; without Bambu Studio there
/// are no lists, and codes outside `GlanceContent`'s table stay "Error <code>". Mac only: the iPhone has no
/// Bambu Studio.
enum BambuCodeList {
    /// Newest first: the lists Bambu Studio downloaded for the printers it has talked to, the copies it unpacked
    /// for itself, then the ones inside the app.
    static var folders: [URL] {
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BambuStudio/hms")
        let apps = [URL(fileURLWithPath: "/Applications"), files.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
            .flatMap { ["BambuStudio.app", "Bambu Studio.app"].map($0.appendingPathComponent) }
            .map { $0.appendingPathComponent("Contents/Resources/hms") }
        return [support.appendingPathComponent("cloud"), support.appendingPathComponent("local")] + apps
    }

    /// Every English description in these folders, keyed by the code's hex digits in capitals (07008010 for
    /// 0700-8010). The first description of a code that isn't blank wins; a code listed only without one maps
    /// to "". Only a description's first paragraph: some go on to a caution about hot parts.
    static func read(folders: [URL]) -> [String: String] {
        var words: [String: String] = [:]
        for folder in folders {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasPrefix("hms_en_") && $0.hasSuffix(".json") }.sorted()
            for name in names {
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let lists = root["data"] as? [String: Any] else { continue }
                // `device_hms` holds the long codes, `device_error` the short ones, each under its language
                // beside a version number.
                for case let list as [String: Any] in lists.values {
                    for case let entry as [String: Any] in (list["en"] as? [Any]) ?? [] {
                        guard let code = (entry["ecode"] as? String)?.uppercased(), words[code]?.isEmpty != false else { continue }
                        words[code] = firstParagraph(entry["intro"] as? String)
                    }
                }
            }
        }
        return words
    }

    private static func firstParagraph(_ text: String?) -> String {
        text?.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }
}
