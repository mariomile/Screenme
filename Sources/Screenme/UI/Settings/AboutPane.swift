import AppKit
import SwiftUI

struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        let commit = Updater.shared.source.map { " · \($0.shortCommit)" } ?? ""
        return "Version \(short) (\(build))\(commit)"
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 20)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text("Screenme").font(.system(size: 26, weight: .bold))
                Text(version).font(.callout).foregroundStyle(.secondary)
            }
            Text("Screenshots, screen recordings and text capture for macOS, from the menu bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 12) {
                Link(destination: URL(string: "https://github.com/mariomile/Screenme")!) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.bordered)
                Button("Welcome Guide") { OnboardingWindow.show() }
            }
            UpdateSection(updater: .shared)
            Text("Open source under the MIT License.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct UpdateSection: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(spacing: 8) {
            if updater.source == nil {
                Text("Updates work on copies installed with scripts/install.sh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Check for Updates") { Task { await updater.check() } }
                    .disabled(updater.isBusy)
                    .help("Fetches the latest changes from GitHub and lists what is new since this copy was installed.")
                status
            }
        }
        .frame(maxWidth: 420)
    }

    @ViewBuilder private var status: some View {
        switch updater.state {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView("Checking…").controlSize(.small)
        case .upToDate:
            Label("Screenme is up to date.", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .available(let commits):
            VStack(spacing: 8) {
                Text(commits.count == 1 ? "1 update available" : "\(commits.count) updates available")
                    .font(.callout.weight(.semibold))
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(commits.prefix(8).enumerated()), id: \.offset) { _, subject in
                        Text("• \(subject)").lineLimit(1)
                    }
                    if commits.count > 8 { Text("and \(commits.count - 8) more").foregroundStyle(.secondary) }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Download and Install") { Task { await updater.update() } }
                    .buttonStyle(.borderedProminent)
                    .help("Pulls the changes, builds Screenme and installs it in Applications. Screenme restarts, and its permissions stay granted.")
            }
        case .updating(let step, let started):
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(step).font(.callout)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Duration.seconds(context.date.timeIntervalSince(started).rounded()),
                             format: .time(pattern: .minuteSecond))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Usually under a minute. Screenme quits and reopens by itself when it is done.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                if FileManager.default.fileExists(atPath: updater.logURL.path) {
                    Button("Show Update Log") { NSWorkspace.shared.open(updater.logURL) }
                        .controlSize(.small)
                        .help("Opens the output of the last update attempt.")
                }
            }
        }
    }
}
