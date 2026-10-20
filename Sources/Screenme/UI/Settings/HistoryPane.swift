import SwiftUI

struct HistoryPane: View {
    var body: some View {
        Form {
            Section {
                PrefIntPicker("Keep captures for", Pref.historyDays,
                              options: [("1 day", 1), ("7 days", 7), ("14 days", 14), ("30 days", 30), ("90 days", 90), ("1 year", 365), ("Forever", 0)])
            } footer: {
                Text("Captures older than this are removed from History. Files you saved to your folder are never touched.")
            }
        }
        .formStyle(.grouped)
    }
}
