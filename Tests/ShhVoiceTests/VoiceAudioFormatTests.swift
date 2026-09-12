import XCTest
import Foundation
import AVFoundation
@testable import ShhVoice

final class VoiceAudioFormatTests: XCTestCase {

    func testSyntheticWavDataFormatAndHeaders() {
        let sampleRate: Double = 16000.0
        let duration: TimeInterval = 0.5 // 0.5s = 8000 samples = 16000 bytes PCM + 44 bytes header = 16044
        let wavData = VoiceAudioFormat.createSyntheticWavData(duration: duration, frequency: 440.0, sampleRate: sampleRate)

        XCTAssertEqual(wavData.count, 44 + 16000)

        // Check RIFF header
        let riff = String(decoding: wavData.prefix(4), as: UTF8.self)
        XCTAssertEqual(riff, "RIFF")

        let wave = String(decoding: wavData[8..<12], as: UTF8.self)
        XCTAssertEqual(wave, "WAVE")

        let fmt = String(decoding: wavData[12..<16], as: UTF8.self)
        XCTAssertEqual(fmt, "fmt ")

        let dataChunk = String(decoding: wavData[36..<40], as: UTF8.self)
        XCTAssertEqual(dataChunk, "data")

        // Channels (offset 22..23) = 1
        let channels = wavData.subdata(in: 22..<24).withUnsafeBytes { $0.load(as: UInt16.self) }
        XCTAssertEqual(channels, 1)

        // Sample rate (offset 24..28) = 16000
        let rate = wavData.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(rate, 16000)

        // Bits per sample (offset 34..36) = 16
        let bits = wavData.subdata(in: 34..<36).withUnsafeBytes { $0.load(as: UInt16.self) }
        XCTAssertEqual(bits, 16)
    }

    func testPcmRecorderSettings() {
        let settings = VoiceAudioFormat.pcmRecorderSettings
        XCTAssertEqual(settings[AVFormatIDKey] as? Int, Int(kAudioFormatLinearPCM))
        XCTAssertEqual(settings[AVSampleRateKey] as? Double, 16000.0)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(settings[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertEqual(settings[AVLinearPCMIsBigEndianKey] as? Bool, false)
        XCTAssertEqual(settings[AVLinearPCMIsFloatKey] as? Bool, false)
        XCTAssertEqual(settings[AVLinearPCMIsNonInterleaved] as? Bool, false)
    }
}
