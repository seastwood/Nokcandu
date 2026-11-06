import SwiftUI
import AppKit
import NokcanduCore

struct CrashReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let game: InstalledGame
    let crash: CrashReports.Explanation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(game.name) crash report").font(.title2.bold())
            Text(crash.title + ". " + crash.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(crash.report).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 260, maxHeight: 420)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(crash.report, forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 640)
    }
}

