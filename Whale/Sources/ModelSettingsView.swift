import SwiftUI

struct ModelInfo: Decodable, Identifiable {
    let id: String
    let label: String
    let size_mb: Int
    let downloaded: Bool
}

struct ModelsResponse: Decodable {
    let models: [ModelInfo]
}

private struct ServerErrorResponse: Decodable {
    let detail: String
}

private struct DownloadProgressResponse: Decodable {
    let percent: Double
}

enum ModelServiceError: LocalizedError {
    case serverUnavailable
    case server(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .serverUnavailable:
            return "Server not running. Launch the app again and retry."
        case .server(let message):
            return message
        case .invalidResponse:
            return "The model service returned an invalid response."
        }
    }
}

enum ModelService {
    private static let baseURL = URL(string: "http://127.0.0.1:8765")!

    static func fetchModels() async throws -> [ModelInfo] {
        let url = baseURL.appendingPathComponent("models")
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            try validate(response: response, data: data)
            return try JSONDecoder().decode(ModelsResponse.self, from: data).models
        } catch {
            throw normalize(error)
        }
    }

    static func download(_ model: ModelInfo) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("models/download"))
        req.httpMethod = "POST"
        let boundary = UUID().uuidString
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.appendField("model_id", value: model.id, boundary: boundary)
        req.httpBody = body
        req.timeoutInterval = 1200

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            try validate(response: response, data: data)
        } catch {
            throw normalize(error)
        }
    }

    static func fetchDownloadProgress(for modelId: String) async -> Double? {
        let encoded = modelId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? modelId
        guard let url = URL(string: "models/download-progress?model_id=\(encoded)", relativeTo: baseURL) else {
            return nil
        }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let resp = try? JSONDecoder().decode(DownloadProgressResponse.self, from: data) else {
            return nil
        }
        return resp.percent > 0.01 ? resp.percent : nil
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ModelServiceError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(ServerErrorResponse.self, from: data).detail)
                ?? String(data: data, encoding: .utf8)
                ?? "Request failed with status \(http.statusCode)."
            throw ModelServiceError.server(detail)
        }
    }

    private static func normalize(_ error: Error) -> Error {
        if let serviceError = error as? ModelServiceError {
            return serviceError
        }

        let message = error.localizedDescription
        if message.contains("Connection refused")
            || message.contains("Could not connect")
            || message.contains("offline") {
            return ModelServiceError.serverUnavailable
        }

        return error
    }
}

struct ModelSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var models: [ModelInfo] = []
    @State private var downloading: Set<String> = []
    @State private var downloadProgress: [String: Double] = [:]
    @State private var error: String?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let error, !models.isEmpty {
                ModelStatusCard(
                    title: "Model issue",
                    message: error,
                    buttonTitle: "Retry",
                    action: { Task { await fetchModels() } }
                )
                .padding(.horizontal, 18)
            }

            content
        }
        .padding(.vertical, 18)
        .task { await fetchModels() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Transcription models")
                .font(.title3.bold())
            Text("Only fully cached models can be activated. Failed downloads stay inactive until they finish cleanly.")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .padding(.horizontal, 18)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && models.isEmpty {
            ModelStatusCard(title: "Loading models…", message: "Checking which models are fully available on this Mac.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 18)
        } else if models.isEmpty {
            ModelStatusCard(
                title: error == nil ? "No models available" : "Could not load models",
                message: error ?? "The app could not find any model entries. Retry once the transcription server is ready.",
                buttonTitle: "Retry",
                action: { Task { await fetchModels() } }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 18)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if !models.contains(where: \.downloaded) {
                    ModelStatusCard(
                        title: "No usable model installed",
                        message: "Download one model to enable transcription. Interrupted downloads stay inactive until they complete successfully."
                    )
                }

                List(models) { model in
                    ModelRow(
                        model: model,
                        isActive: store.activeModelId == model.id && model.downloaded,
                        isDownloading: downloading.contains(model.id),
                        downloadProgress: downloadProgress[model.id],
                        onSelect: { store.activeModelId = model.id },
                        onDownload: { Task { await download(model) } }
                    )
                }
                .listStyle(.inset)
            }
            .padding(.horizontal, 18)
        }
    }

    private func fetchModels() async {
        if models.isEmpty {
            isLoading = true
        }

        do {
            let fetched = try await ModelService.fetchModels()
            models = fetched
            error = nil
            let downloadedIds = fetched.filter { $0.downloaded }.map { $0.id }
            store.reconcileActiveModel(downloadedModelIds: downloadedIds)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    private func download(_ model: ModelInfo) async {
        downloading.insert(model.id)
        defer {
            downloading.remove(model.id)
            downloadProgress.removeValue(forKey: model.id)
        }

        let pollTask = Task {
            while !Task.isCancelled {
                if let progress = await ModelService.fetchDownloadProgress(for: model.id) {
                    await MainActor.run {
                        downloadProgress[model.id] = progress
                    }
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
        defer { pollTask.cancel() }

        do {
            try await ModelService.download(model)
            await fetchModels()
        } catch {
            self.error = "\(model.label) failed to download. \(error.localizedDescription)"
            await fetchModels()
        }
    }
}

struct ModelStatusCard: View {
    let title: String
    let message: String
    var buttonTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Row

struct ModelRow: View {
    let model: ModelInfo
    let isActive: Bool
    let isDownloading: Bool
    var downloadProgress: Double? = nil
    let onSelect: () -> Void
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.label)
                    .fontWeight(isActive ? .semibold : .regular)
                Text(formattedSize)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Spacer()

            actionView
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if model.downloaded && !isActive {
                onSelect()
            }
        }
    }

    @ViewBuilder
    private var actionView: some View {
        if isDownloading {
            VStack(alignment: .trailing, spacing: 4) {
                if let progress = downloadProgress {
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: progress)
                        .frame(width: 90)
                        .tint(.blue)
                } else {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                        Text("Downloading…")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                }
            }
        } else if isActive && model.downloaded {
            Label("Active", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.blue)
                .font(.callout)
                .fontWeight(.medium)
        } else if model.downloaded {
            Button("Activate", action: onSelect)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else {
            Button("Download", action: onDownload)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var formattedSize: String {
        model.size_mb >= 1000
            ? String(format: "%.1f GB", Double(model.size_mb) / 1000)
            : "\(model.size_mb) MB"
    }
}

// MARK: - Data helper

extension Data {
    mutating func appendField(_ name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append(value.data(using: .utf8)!)
        append("\r\n".data(using: .utf8)!)
        append("--\(boundary)--\r\n".data(using: .utf8)!)
    }
}
