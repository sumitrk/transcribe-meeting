import AVFoundation
import ScreenCaptureKit
import Foundation

@MainActor
class AudioRecorder: NSObject, ObservableObject {

    // MARK: - State

    @Published var isRecording = false

    // MARK: - Private

    private var scStream: SCStream?
    private var micEngine: AVAudioEngine?

    private var systemAudioSamples: [Float] = []
    private var micSamples: [Float] = []
    private let lock = NSLock()

    private let sampleRate: Double = 16_000

    // MARK: - Public API

    func startRecording() async throws {
        guard !isRecording else { return }

        systemAudioSamples = []
        micSamples = []

        try await startSystemAudioCapture()
        try startMicCapture()

        isRecording = true
        print("AudioRecorder: recording started")
    }

    /// Stop recording and write mixed audio to a temp WAV. Returns the file URL.
    func stopRecording() async throws -> URL {
        guard isRecording else { throw RecorderError.notRecording }

        // Stop both capture streams
        try? await scStream?.stopCapture()
        scStream = nil

        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil

        isRecording = false
        print("AudioRecorder: recording stopped")

        return try mixAndWriteWAV()
    }

    // MARK: - System Audio (ScreenCaptureKit)

    private func startSystemAudioCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )

        guard let display = content.displays.first else {
            throw RecorderError.noDisplay
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = 1

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(
            self,
            type: .audio,
            sampleHandlerQueue: .global(qos: .userInteractive)
        )
        try await stream.startCapture()
        self.scStream = stream
        print("AudioRecorder: ScreenCaptureKit audio started")
    }

    // MARK: - Microphone (AVAudioEngine)

    private func startMicCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 1
        ) else {
            throw RecorderError.formatError
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: inputFormat
        ) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = self.convertAndExtract(buffer, from: inputFormat, to: targetFormat)
            self.lock.lock()
            self.micSamples.append(contentsOf: samples)
            self.lock.unlock()
        }

        try engine.start()
        self.micEngine = engine
        print("AudioRecorder: microphone capture started")
    }

    // MARK: - Mix + Write WAV

    private func mixAndWriteWAV() throws -> URL {
        lock.lock()
        let sys = systemAudioSamples
        let mic = micSamples
        lock.unlock()

        let length = max(sys.count, mic.count)
        guard length > 0 else { throw RecorderError.noAudioCaptured }

        // Pad shorter buffer
        let sysPad = sys + [Float](repeating: 0, count: max(0, length - sys.count))
        let micPad = mic + [Float](repeating: 0, count: max(0, length - mic.count))

        // Mix: average both streams
        var mixed = [Float](repeating: 0, count: length)
        for i in 0..<length {
            mixed[i] = (sysPad[i] + micPad[i]) / 2.0
        }

        // Float [-1, 1] → Int16
        let int16Samples = mixed.map { s -> Int16 in
            Int16(max(-1.0, min(1.0, s)) * Float(Int16.max))
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-\(Int(Date().timeIntervalSince1970)).wav")
        try writeWAV(samples: int16Samples, sampleRate: Int(sampleRate), to: url)

        let sizeMB = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0
        print("AudioRecorder: WAV saved → \(url.lastPathComponent) (\(sizeMB / 1024)KB)")
        return url
    }

    // MARK: - WAV Writer

    private func writeWAV(samples: [Int16], sampleRate: Int, to url: URL) throws {
        var data = Data()
        let dataSize = samples.count * 2
        let byteRate = sampleRate * 2  // 16-bit mono

        data.appendString("RIFF")
        data.appendUInt32(UInt32(36 + dataSize))
        data.appendString("WAVE")
        data.appendString("fmt ")
        data.appendUInt32(16)          // chunk size
        data.appendUInt16(1)           // PCM
        data.appendUInt16(1)           // mono
        data.appendUInt32(UInt32(sampleRate))
        data.appendUInt32(UInt32(byteRate))
        data.appendUInt16(2)           // block align
        data.appendUInt16(16)          // bits per sample
        data.appendString("data")
        data.appendUInt32(UInt32(dataSize))
        for s in samples { data.appendUInt16(UInt16(bitPattern: s)) }

        try data.write(to: url)
    }

    // MARK: - Audio helpers

    private func convertAndExtract(_ buffer: AVAudioPCMBuffer,
                                   from: AVAudioFormat,
                                   to: AVAudioFormat) -> [Float] {
        guard let converter = AVAudioConverter(from: from, to: to) else { return [] }
        let ratio = to.sampleRate / from.sampleRate
        let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let out = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: outFrames) else { return [] }
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channelData = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(out.frameLength)))
    }
}

// MARK: - SCStreamOutput (system audio callbacks)

extension AudioRecorder: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer buffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .audio,
              let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
                                    lengthAtOffsetOut: nil,
                                    totalLengthOut: &length,
                                    dataPointerOut: &dataPointer)
        guard let ptr = dataPointer, length > 0 else { return }

        let floatCount = length / MemoryLayout<Float>.size
        let samples = Array(UnsafeBufferPointer(
            start: UnsafeRawPointer(ptr).bindMemory(to: Float.self, capacity: floatCount),
            count: floatCount
        ))

        lock.lock()
        systemAudioSamples.append(contentsOf: samples)
        lock.unlock()
    }
}

// MARK: - Errors

enum RecorderError: LocalizedError {
    case notRecording
    case noDisplay
    case formatError
    case noAudioCaptured

    var errorDescription: String? {
        switch self {
        case .notRecording:      return "Not currently recording"
        case .noDisplay:         return "No display found for audio capture"
        case .formatError:       return "Audio format conversion failed"
        case .noAudioCaptured:   return "No audio was captured"
        }
    }
}

// MARK: - Data WAV helpers

private extension Data {
    mutating func appendString(_ s: String) { append(contentsOf: s.utf8) }
    mutating func appendUInt16(_ v: UInt16) { var x = v.littleEndian; append(Data(bytes: &x, count: 2)) }
    mutating func appendUInt32(_ v: UInt32) { var x = v.littleEndian; append(Data(bytes: &x, count: 4)) }
}
