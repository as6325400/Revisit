import SwiftUI
import UIKit

/// Toolbar menu for exporting a workout as a file.
struct ExportMenu: View {
    let record: WorkoutRecord

    @State private var isExporting = false
    @State private var exportedFile: ExportedFile?
    @State private var errorMessage: String?

    var body: some View {
        Menu {
            Button {
                Task { await exportFIT() }
            } label: {
                Label("匯出 .fit 檔", systemImage: "doc.badge.arrow.up")
                Text("Strava、Garmin Connect 等都能匯入")
            }
        } label: {
            if isExporting {
                ProgressView()
            } else {
                Image(systemName: "square.and.arrow.up")
            }
        }
        .disabled(isExporting)
        .accessibilityLabel("匯出")
        #if DEBUG
        .task {
            if DemoData.exportsFIT { await exportFIT() }
        }
        #endif
        .sheet(item: $exportedFile) { file in
            ShareSheet(items: [file.url])
                .presentationDetents([.medium, .large])
        }
        .alert("無法匯出", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func exportFIT() async {
        isExporting = true
        defer { isExporting = false }
        do {
            let url = try await AppModel.shared.fitExporter.export(record)
            #if DEBUG
            print("FITEXPORT \(url.path)")
            #endif
            exportedFile = ExportedFile(url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ExportedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet (Save to Files, AirDrop, other apps).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
