import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

private enum Source { case mic, system }

struct TrainerError: LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}

final class SystemAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let track: AudioTrack
    let failure: (Error) -> Void
    init(track: AudioTrack, failure: @escaping (Error) -> Void) {
        self.track = track
        self.failure = failure
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        failure(error)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let format = withUnsafePointer(to: description, AVAudioFormat.init(streamDescription:)),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples))
        else { return }
        pcm.frameLength = pcm.frameCapacity
        let copied = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0,
            frameCount: Int32(pcm.frameLength), into: pcm.mutableAudioBufferList)
        if copied == noErr { track.add(pcm) }
    }
}

@MainActor
final class VoiceCapture {
    private var mic: AVAudioEngine?
    private var stream: SCStream?
    private var streamOutput: SystemAudioOutput?
    private var tracks: [Source: AudioTrack] = [:]

    func chunk(frames: Int) -> Data {
        let microphone = tracks[.mic]?.take(frames)
        let systemAudio = tracks[.system]?.take(frames)
        let output: [Int16]
        if let microphone, let systemAudio {
            output = zip(microphone, systemAudio).map { left, right in
                Int16(clamping: Int(left) + Int(right))
            }
        } else {
            output = microphone ?? systemAudio ?? Array(repeating: 0, count: frames)
        }
        return output.withUnsafeBytes { Data($0) }
    }

    func start(microphone: Bool, system: Bool, onSystemStop: @escaping (Error) -> Void) async throws {
        guard microphone || system else { throw TrainerError("Выбери источник звука.") }
        tracks.removeAll()
        do {
            if microphone {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw TrainerError("Разреши микрофон для «UWC Тренировка» в настройках конфиденциальности macOS.")
                }
                let engine = AVAudioEngine()
                let node = engine.inputNode
                let format = node.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else {
                    throw TrainerError("Mac не видит микрофон.")
                }
                let track = AudioTrack()
                tracks[.mic] = track
                node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in track.add(buffer) }
                mic = engine
                try engine.start()
            }
            if system {
                guard CGPreflightScreenCaptureAccess() else {
                    _ = CGRequestScreenCaptureAccess()
                    throw TrainerError("Для звука Mac разреши запись экрана в настройках macOS, затем перезапусти «UWC Тренировка».")
                }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else { throw TrainerError("Mac не видит активный экран.") }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                config.queueDepth = 3
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48_000
                config.channelCount = 1
                let track = AudioTrack()
                let output = SystemAudioOutput(track: track, failure: onSystemStop)
                let recording = SCStream(filter: filter, configuration: config, delegate: output)
                try recording.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "uwc.system-audio"))
                tracks[.system] = track
                streamOutput = output
                stream = recording
                try await recording.startCapture()
            }
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        if let mic {
            mic.inputNode.removeTap(onBus: 0)
            mic.stop()
            self.mic = nil
        }
        if let stream {
            self.stream = nil
            try? await stream.stopCapture()
            streamOutput = nil
        }
        tracks.removeAll()
    }
}

final class AudioTrack {
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var phase = 0
    private var sum: Float = 0
    private var count = 0
    private var sampleRate = 0

    func add(_ buffer: AVAudioPCMBuffer) {
        let sourceRate = Int(buffer.format.sampleRate)
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let stride = buffer.stride
        let floats = buffer.floatChannelData
        let ints = buffer.int16ChannelData
        guard sourceRate > 0, frames > 0, channels > 0, floats != nil || ints != nil else { return }
        lock.lock()
        defer { lock.unlock() }
        if sampleRate != sourceRate {
            sampleRate = sourceRate
            phase = 0
            count = 0
            sum = 0
        }
        for frame in 0..<frames {
            var mono: Float = 0
            for channel in 0..<channels {
                if let floats { mono += floats[channel][frame * stride] }
                else if let ints { mono += Float(ints[channel][frame * stride]) / 32768 }
            }
            sum += mono / Float(channels)
            count += 1
            phase += 16_000
            if phase >= sourceRate {
                let average = sum / Float(count)
                let pcm = average.isFinite ? Int16(max(-1, min(1, average)) * 32767) : 0
                while phase >= sourceRate {
                    samples.append(pcm)
                    phase -= sourceRate
                }
                sum = 0
                count = 0
            }
        }
        if samples.count > 16_000 { samples.removeFirst(samples.count - 16_000) }
    }

    func take(_ count: Int) -> [Int16] {
        lock.lock()
        defer { lock.unlock() }
        let available = min(count, samples.count)
        let chunk = Array(samples.prefix(available))
        samples.removeFirst(available)
        return chunk + Array(repeating: 0, count: count - available)
    }
}
