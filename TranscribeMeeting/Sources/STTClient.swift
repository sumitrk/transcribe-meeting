import Foundation
import MLXAudioSTT
import MLXAudioCore

/// Wraps Parakeet (via mlx-audio-swift) for local on-device transcription.
/// The model is downloaded from HuggingFace on first use (~600 MB) and cached.
actor STTClient {
    private var parakeet: ParakeetModel?
    private let modelId = "mlx-community/parakeet-tdt-0.6b-v3"

    func transcribe(wavURL: URL) async throws -> String {
        // Load audio from WAV into MLXArray
        let (_, audio) = try loadAudioArray(from: wavURL)

        // Load model lazily — downloaded + cached by mlx-audio-swift on first call
        if parakeet == nil {
            parakeet = try await ParakeetModel.fromPretrained(modelId)
        }
        guard let model = parakeet else {
            throw STTError.modelNotLoaded
        }

        // generate() is synchronous MLX inference — run on a background thread
        // so we don't block Swift concurrency's cooperative thread pool
        return try await Task.detached(priority: .userInitiated) {
            model.generate(audio: audio).text
        }.value
    }
}

enum STTError: LocalizedError {
    case modelNotLoaded
    var errorDescription: String? { "Parakeet model failed to load" }
}
