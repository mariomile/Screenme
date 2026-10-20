import SwiftUI

struct QuickAccessPane: View {
    @AppStorage(Pref.quickAccessPosition.name) private var position = Pref.quickAccessPosition.defaultValue

    var body: some View {
        Form {
            Section {
                HStack(spacing: 20) {
                    Spacer()
                    positionChoice("Bottom left", value: .bottomLeft)
                    positionChoice("Bottom right", value: .bottomRight)
                    Spacer()
                }
                .padding(.vertical, 6)
            } header: {
                Text("Position")
            } footer: {
                Text("Cards appear on the screen where your mouse is, and stack upward.")
            }

            Section {
                PrefIntPicker("Close automatically", Pref.quickAccessAutoClose,
                              options: [("Never", 0), ("After 3 seconds", 3), ("After 5 seconds", 5), ("After 10 seconds", 10), ("After 15 seconds", 15), ("After 30 seconds", 30)])
            } header: {
                Text("Behavior")
            } footer: {
                Text("The timer pauses while you hover a card. Drag a card into any app to use it, or swipe it toward the screen edge to dismiss.")
            }
        }
        .formStyle(.grouped)
    }

    private func positionChoice(_ title: String, value: QuickAccessPosition) -> some View {
        let selected = position == value
        let right = value == .bottomRight
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { position = value }
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: right ? .bottomTrailing : .bottomLeading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: 26, height: 18)
                        .padding(7)
                }
                .frame(width: 120, height: 76)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 2 : 1)
                )
                Text(title).font(.callout).foregroundStyle(selected ? Color.primary : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
