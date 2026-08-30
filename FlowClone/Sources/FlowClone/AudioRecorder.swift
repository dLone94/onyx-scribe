import AVFoundation

/// Captures microphone audio and delivers 16 kHz mono Float32 samples
/// (the input format Parakeet/FluidAudio expects).
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()

    /// Live input level (0…1, soft-knee scaled RMS), delivered on the main thread.
    /// Drives the pill's waveform. `@Sendable`: it is read from the audio tap.
    var onLevel: (@Sendable (Float) -> Void)?

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
    )!

    enum RecorderError: Error { case noConverter }

    func start() throws {
        lock.lock()
        samples.removeAll()
        lock.unlock()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat)
        // Without a converter, every buffer would silently drop and the user
        // would record into a void — surface it as a mic error instead.
        guard converter != nil else { throw RecorderError.noConverter }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // A failed start must not leave a poisoned recorder behind (tap
            // installed, engine dead) — remove the tap and reset everything so
            // the next start() attempt begins from a clean slate.
            input.removeTap(onBus: 0)
            converter = nil
            lock.lock()
            samples.removeAll()
            lock.unlock()
            throw error
        }
    }

    /// Copy of everything recorded so far (recording continues). Feeds the
    /// live-transcript partial loop.
    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    /// Stops capture and returns everything recorded as 16 kHz mono samples.
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        defer { lock.unlock() }
        let out = samples
        samples.removeAll()
        return out
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var convError: NSError?
        converter.convert(to: converted, error: &convError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard convError == nil, converted.frameLength > 0, let data = converted.floatChannelData else { return }

        let frameCount = Int(converted.frameLength)
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frameCount))
        lock.unlock()

        if let onLevel {
            var sum: Float = 0
            let ptr = data[0]
            for i in 0..<frameCount { sum += ptr[i] * ptr[i] }
            let rms = (sum / Float(max(frameCount, 1))).squareRoot()
            let level = min(1, rms * 18) // soft-knee scale to 0…1
            DispatchQueue.main.async { onLevel(level) }
        }
    }
}
