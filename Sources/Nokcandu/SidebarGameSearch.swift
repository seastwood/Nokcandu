import SwiftUI

/// Explicit placement keeps search beneath the section selector on macOS 14 and later.
struct SidebarGameSearch: View {
    @Binding var query: String
    @Binding var focusRequest: Bool
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search games", text: $query)
                .textFieldStyle(.plain).focused($focused)
                .accessibilityLabel("Search games")
            if !query.isEmpty {
                Button { query = ""; focused = true } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear game search")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .onAppear { consumeFocusRequest() }
        .onChange(of: focusRequest) { _, _ in consumeFocusRequest() }
    }
    private func consumeFocusRequest() {
        if focusRequest { focused = true; focusRequest = false }
    }
}
