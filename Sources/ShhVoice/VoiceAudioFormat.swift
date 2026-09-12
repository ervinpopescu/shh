import Foundation
import AVFoundation

public enum VoiceAudioFormat {
    public static let sampleRate: Double = 16000.0
    public static let channelCount: Int = 1
    public static let bitDepth: Int = 16
    public static let fileExtension: String = "wav"

    /// Standard linear PCM settings for 16kHz mono 16-bit audio recording.
    public static var pcmRecorderSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    /// Generates a valid 16kHz mono 16-bit PCM WAV Data buffer containing a sine wave or silence.
    /// Useful for synthetic test fixtures and unit tests without hardware capture.
    public static func createSyntheticWavData(
        duration: TimeInterval,
        frequency: Double = 440.0,
        sampleRate: Double = VoiceAudioFormat.sampleRate
    ) -> Data {
        let totalSamples = max(Int(duration * sampleRate), 1)
        let bytesPerSample = 2 // 16-bit
        let dataSize = UInt32(totalSamples * bytesPerSample)
        let fileSize = UInt32(36 + dataSize)

        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))

        // RIFF header
        data.append(contentsOf: [UInt8]("RIFF".utf8))
        var riffSize = fileSize.littleEndian
        data.append(Data(bytes: &riffSize, count: 4))
        data.append(contentsOf: [UInt8]("WAVE".utf8))

        // fmt subchunk
        data.append(contentsOf: [UInt8]("fmt ".utf8))
        var subchunk1Size = UInt32(16).littleEndian
        data.append(Data(bytes: &subchunk1Size, count: 4))
        var audioFormat = UInt16(1).littleEndian // PCM
        data.append(Data(bytes: &audioFormat, count: 2))
        var channels = UInt16(1).littleEndian // Mono
        data.append(Data(bytes: &channels, count: 2))
        var rate = UInt32(sampleRate).littleEndian
        data.append(Data(bytes: &rate, count: 4))
        var byteRate = UInt32(Double(sampleRate) * Double(1) * Double(bytesPerSample)).littleEndian
        data.append(Data(bytes: &byteRate, count: 4))
        var blockAlign = UInt16(1 * bytesPerSample).littleEndian
        data.append(Data(bytes: &blockAlign, count: 2))
        var bitsPerSample = UInt16(16).littleEndian
        data.append(Data(bytes: &bitsPerSample, count: 2))

        // data subchunk
        data.append(contentsOf: [UInt8]("data".utf8))
        var subchunk2Size = dataSize.littleEndian
        data.append(Data(bytes: &subchunk2Size, count: 4))

        // PCM samples
        let twoPi = 2.0 * Double.pi
        for i in 0..<totalSamples {
            let t = Double(i) / sampleRate
            let sampleVal: Int16
            if frequency > 0 {
                let sampleFloat = sin(twoPi * frequency * t) * 0.5
                sampleVal = Int16(max(-32767.0, min(32767.0, sampleFloat * 32767.0)))
            } else {
                sampleVal = 0
            }
            var leSample = sampleVal.littleEndian
            data.append(Data(bytes: &leSample, count: 2))
        }

        return data
    }
}
