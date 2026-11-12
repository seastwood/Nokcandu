import SwiftUI

/// Keep sidebar actions outside the list's scrolling/drawing area on every supported macOS.
struct SidebarFooter<Footer: View>: ViewModifier {
    let footer: Footer
    init(@ViewBuilder footer: () -> Footer) { self.footer = footer() }
    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            content.frame(minHeight: 0, maxHeight: .infinity).clipped()
            Divider()
            footer.fixedSize(horizontal: false, vertical: true)
        }
    }
}
