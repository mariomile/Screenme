import Foundation

/// The agent skill (`skills/screenme/SKILL.md` in the repo), which the app carries in its Resources, for
/// `screenme skill`: an agent installs or reads it without the repo.
enum Skill {
    static let fileName = "SKILL.md"

    /// `Screenme.app/Contents/Resources/SKILL.md` next to `Contents/Helpers/screenme`, following the link on PATH,
    /// else the copy in /Applications.
    static func url(executable: URL? = Bundle.main.executableURL) -> URL? {
        let contents = executable?.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [contents?.appendingPathComponent("Resources/\(fileName)"),
                          URL(fileURLWithPath: "/Applications/Screenme.app/Contents/Resources/\(fileName)")]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
