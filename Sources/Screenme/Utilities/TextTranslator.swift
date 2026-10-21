import AppKit
import NaturalLanguage
import SwiftUI
import Translation

extension Pref {
    /// A `Locale.Language` identifier ("it", "en-GB"), or empty for the system language.
    static let translateTarget = PrefKey(name: "translateTarget", defaultValue: "")
}

/// Recognized text and what it became.
struct TextTranslation {
    let original: String
    let text: String
    let source: Locale.Language
    let target: Locale.Language
}

enum TranslateError: LocalizedError {
    case unknownLanguage
    case sameLanguage(String)
    case unsupported(from: String, to: String)
    case notInstalled(from: String, to: String)

    var errorDescription: String? {
        switch self {
        case .unknownLanguage: "Screenme could not tell which language the text is in."
        case .sameLanguage(let name): "The text is already in \(name)."
        case .unsupported(let from, let to): "Translating from \(from) to \(to) is not supported."
        case .notInstalled(let from, let to): "\(from) and \(to) are not downloaded for translation yet."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notInstalled:
            "Download both in System Settings > General > Language & Region > Translation Languages, then try again."
        case .unsupported:
            "Pick another language under Translate into in Screenme Settings > Text Recognition, or check System Settings > General > Language & Region > Translation Languages."
        case .unknownLanguage, .sameLanguage:
            nil
        }
    }
}

/// On-device translation with Apple's Translation framework. Nothing leaves the Mac, so a language pair
/// must be downloaded first; Screenme never starts the download itself.
@MainActor
enum TextTranslator {
    /// Languages the framework translates, for the Translate into picker, sorted by name.
    static func targetLanguages() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages.sorted { name(of: $0) < name(of: $1) }
    }

    static func name(of language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    /// Translates into `Pref.translateTarget`, detecting the source language.
    static func translate(_ text: String) async throws -> TextTranslation {
        let availability = LanguageAvailability()
        let supported = await availability.supportedLanguages
        let chosen = Prefs[Pref.translateTarget]
        let wanted = Locale.Language(identifier: chosen.isEmpty ? Locale.preferredLanguages.first ?? "en" : chosen)
        guard let detected = NLLanguageRecognizer.dominantLanguage(for: text) else { throw TranslateError.unknownLanguage }
        let detectedLanguage = Locale.Language(identifier: detected.rawValue)
        guard let source = closest(detectedLanguage, in: supported) else {
            throw TranslateError.unsupported(from: name(of: detectedLanguage), to: name(of: wanted))
        }
        guard let target = closest(wanted, in: supported) else {
            throw TranslateError.unsupported(from: name(of: source), to: name(of: wanted))
        }
        if source.languageCode == target.languageCode, script(of: source) == script(of: target) {
            throw TranslateError.sameLanguage(name(of: target))
        }

        switch await availability.status(from: source, to: target) {
        case .installed: break
        case .supported: throw TranslateError.notInstalled(from: name(of: source), to: name(of: target))
        case .unsupported: throw TranslateError.unsupported(from: name(of: source), to: name(of: target))
        @unknown default: throw TranslateError.unsupported(from: name(of: source), to: name(of: target))
        }

        do {
            let translated: String
            if #available(macOS 26.0, *) {
                translated = try await TranslationSession(installedSource: source, target: target).translate(text).targetText
            } else {
                translated = try await HiddenTranslationHost.translate(text, from: source, to: target)
            }
            return TextTranslation(original: text, text: translated, source: source, target: target)
        } catch {
            if TranslationError.unableToIdentifyLanguage ~= error { throw TranslateError.unknownLanguage }
            if TranslationError.unsupportedLanguagePairing ~= error || TranslationError.unsupportedSourceLanguage ~= error
                || TranslationError.unsupportedTargetLanguage ~= error {
                throw TranslateError.unsupported(from: name(of: source), to: name(of: target))
            }
            if #available(macOS 26.0, *), TranslationError.notInstalled ~= error {
                throw TranslateError.notInstalled(from: name(of: source), to: name(of: target))
            }
            throw error
        }
    }

    // MARK: Languages

    /// The supported language that stands for `language`: the same language and script, the same region
    /// when there is one ("en-GB"), otherwise its main variant ("en" is "en-US").
    private static func closest(_ language: Locale.Language, in supported: [Locale.Language]) -> Locale.Language? {
        let matches = supported.filter { $0.languageCode == language.languageCode && script(of: $0) == script(of: language) }
        let main = Locale.Language(identifier: language.maximalIdentifier).region
        return matches.first { $0.region != nil && $0.region == language.region }
            ?? matches.first { Locale.Language(identifier: $0.maximalIdentifier).region == main }
            ?? matches.first
    }

    /// "zh-TW" and "zh-Hant" are the same script; "zh" is not.
    private static func script(of language: Locale.Language) -> Locale.Script? {
        Locale.Language(identifier: language.maximalIdentifier).script
    }
}

// MARK: - macOS 15

/// Before macOS 26 a `TranslationSession` only comes from SwiftUI's `.translationTask`, so a tiny invisible
/// window hosts one for the length of a single translation.
@MainActor
private enum HiddenTranslationHost {
    static func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        let panel = FloatingPanel(frame: CGRect(x: 0, y: 0, width: 1, height: 1), level: .normal, hasShadow: false, ignoresMouse: true)
        defer { panel.orderOut(nil) }
        return try await withCheckedThrowingContinuation { continuation in
            let view = TranslationTaskView(configuration: TranslationSession.Configuration(source: source, target: target), text: text) { result in
                continuation.resume(with: result)
            }
            panel.contentView = NSHostingView(rootView: view)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
    }
}

private struct TranslationTaskView: View {
    let configuration: TranslationSession.Configuration
    let text: String
    let done: @MainActor (Result<String, Error>) -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(configuration) { session in
                let result: Result<String, Error>
                do {
                    result = .success(try await session.translate(text).targetText)
                } catch {
                    result = .failure(error)
                }
                done(result)
            }
    }
}
