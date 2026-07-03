#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

// MARK: - SessionBundle (decode-only, local to this view)

private struct SessionBundle: Decodable {
    let podiumExportVersion: String?
    let session: BundleSession
    let agents: [BundleAgent]?
    let eventCount: Int?

    struct BundleSession: Decodable {
        let id: String
        let name: String?
        let status: String?
        let cwd: String?
        let model: String?
        let startedAt: Date?
        let endedAt: Date?
        let cost: Double?
    }

    struct BundleAgent: Decodable, Identifiable {
        let id: String
        let name: String
        let type: String?
        let status: String?
    }
}

// MARK: - Import Session View

struct ImportSessionView: View {
    @Environment(AppState.self) var state

    enum ImportViewState {
        case upload, preview, importing, success
    }

    @State private var viewState: ImportViewState = .upload
    @State private var bundle: SessionBundle? = nil
    @State private var rawBundleData: Data? = nil
    @State private var errorMessage: String? = nil
    @State private var isShowingFilePicker = false
    @State private var pastedJSON = ""
    @State private var showPasteArea = false
    @State private var importedSessionId: String? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                switch viewState {
                case .upload:
                    uploadView
                case .preview:
                    if let b = bundle {
                        previewView(b)
                    }
                case .importing:
                    importingView
                case .success:
                    successView
                }
            }
            .padding(32)
        }
        .navigationTitle("Import Session")
    }

    // MARK: - Upload State

    private var uploadView: some View {
        VStack(spacing: 20) {
            // Drop zone
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .frame(height: 200)

                VStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Drop a Podium export .json here")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Browse Files…") { isShowingFilePicker = true }
                        .buttonStyle(.bordered)
                }
            }
            .onDrop(of: [.json, .fileURL], isTargeted: nil) { providers in
                handleDrop(providers)
                return true
            }

            // Paste toggle
            Button(showPasteArea ? "Hide paste area" : "Paste JSON instead") {
                withAnimation { showPasteArea.toggle() }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.callout)

            if showPasteArea {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $pastedJSON)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 140)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                    Button("Load from Paste") {
                        loadFromString(pastedJSON)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pastedJSON.isEmpty)
                }
            }

            if let err = errorMessage {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .fileImporter(isPresented: $isShowingFilePicker, allowedContentTypes: [.json]) { result in
            if let url = try? result.get(), let data = try? Data(contentsOf: url) {
                loadFromData(data)
            }
        }
    }

    // MARK: - Preview State

    private func previewView(_ b: SessionBundle) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ready to Import")
                        .font(.title3.weight(.semibold))
                    if let v = b.podiumExportVersion {
                        Text("Export version \(v)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button("Start Over") {
                    bundle = nil
                    rawBundleData = nil
                    errorMessage = nil
                    withAnimation { viewState = .upload }
                }
                .foregroundStyle(.secondary)
            }

            // Session card
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Session")

                HStack(spacing: 14) {
                    if let status = b.session.status {
                        StatusDot(
                            color: Theme.color(for: status),
                            active: status.lowercased() == "active"
                        )
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(b.session.name ?? Theme.projectName(from: b.session.cwd))
                            .font(.callout.weight(.medium))
                        if let cwd = b.session.cwd {
                            Text(cwd)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        if let status = b.session.status {
                            StatusBadge(
                                label: status.capitalized,
                                color: Theme.color(for: status)
                            )
                        }
                        if let cost = b.session.cost, cost > 0 {
                            Text(Theme.formatCost(cost))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)
                .glassCard(radius: 12)
            }

            // Stats row
            HStack(spacing: 12) {
                if let agents = b.agents {
                    Label("\(agents.count) agents", systemImage: "person.2")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let count = b.eventCount {
                    Label("\(count) events", systemImage: "bolt")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            // Import button
            Button("Import Session") {
                guard let data = rawBundleData else { return }
                withAnimation { viewState = .importing }
                Task {
                    do {
                        let id = try await state.importSession(data: data)
                        importedSessionId = id.isEmpty ? nil : id
                        withAnimation { viewState = .success }
                    } catch {
                        errorMessage = "Import failed: \(error.localizedDescription)"
                        withAnimation { viewState = .preview }
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if let err = errorMessage {
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Importing State

    private var importingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.cyan)
            Text("Importing session…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Success State

    private var successView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            Text("Session Imported")
                .font(.title2.weight(.semibold))

            Text("The session has been added to your Podium database.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                if let id = importedSessionId {
                    Button("View Session") {
                        state.selectedSessionId = id
                        state.navigationRequest = .sessions
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button("Import Another") {
                    bundle = nil
                    rawBundleData = nil
                    importedSessionId = nil
                    withAnimation { viewState = .upload }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Helpers

    private func handleDrop(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        if provider.hasItemConformingToTypeIdentifier(UTType.json.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.json.identifier) { data, _ in
                if let data {
                    DispatchQueue.main.async { self.loadFromData(data) }
                }
            }
        } else {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil),
                   let fileData = try? Data(contentsOf: url) {
                    DispatchQueue.main.async { self.loadFromData(fileData) }
                }
            }
        }
    }

    private func loadFromString(_ str: String) {
        guard let data = str.data(using: .utf8) else {
            errorMessage = "Could not parse JSON"
            return
        }
        loadFromData(data)
    }

    private func loadFromData(_ data: Data) {
        errorMessage = nil
        guard let decoded = try? JSONDecoder.podium.decode(SessionBundle.self, from: data) else {
            errorMessage = "Invalid format — not a valid Podium export bundle."
            return
        }
        rawBundleData = data
        bundle = decoded
        withAnimation { viewState = .preview }
    }
}

#endif
