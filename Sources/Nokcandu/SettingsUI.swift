import SwiftUI

// Uniform settings layout. Every setting is one row: its name (with an (i) button when there's more to say) on
// the left, its control on the right. Explanations live in the (i) popovers; only things the user must notice
// (warnings, why something is unavailable, live status) stay visible as notes.

/// (i) button: the explanation behind a setting, in a popover.
struct InfoButton: View {
    let text: String
    @State private var shown = false
    init(_ text: String) { self.text = text }

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("More about this")
        .accessibilityLabel("More about this")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .frame(width: 340, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .textSelection(.enabled)
        }
    }
}

/// Standard width for pickers and menus in a setting row, so controls line up down the page.
let settingControlWidth: CGFloat = 220

/// One setting: name and (i) on the left, its control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var info: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(title)
            if let info, !info.isEmpty { InfoButton(info) }
            Spacer(minLength: 12)
            control()
        }
    }
}

/// An on/off setting, as a switch on the right.
struct SettingToggle: View {
    let title: String
    var info: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(title: title, info: info) {
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}

/// A short line for things the user must notice: warnings, why something is unavailable, live status.
struct SettingNote: View {
    let text: String
    var warning = false
    init(_ text: String, warning: Bool = false) { self.text = text; self.warning = warning }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if warning { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption) }
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A titled group of settings on a game's page.
struct SettingsSection<Content: View>: View {
    let title: String
    var info: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                if let info, !info.isEmpty { InfoButton(info) }
            }
        }
    }
}
