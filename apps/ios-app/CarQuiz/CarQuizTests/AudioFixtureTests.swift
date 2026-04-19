//
//  AudioFixtureTests.swift
//  HangsTests
//
//  Tests for validating audio test fixtures used in the test suite.
//  These tests verify that bundled audio files are valid and meet
//  the requirements for various test scenarios.
//

import Foundation
import Testing
@testable import CarQuiz

// MARK: - Audio Fixture Validation Tests

@Suite("Audio Fixture Tests")
struct AudioFixtureTests {

    // MARK: - Test Bundle Helper

    /// Returns the test bundle containing fixture resources
    private var testBundle: Bundle {
        Bundle(for: BundleToken.self)
    }

    // MARK: - TTS Sample Tests

    @Test("TTS sample meets minimum size for valid audio")
    func ttsSampleValidSize() throws {
        let url = try #require(testBundle.url(forResource: "tts_sample", withExtension: "mp3"))
        let data = try Data(contentsOf: url)

        // TTS sample should be well above the 500-byte rejection threshold
        #expect(data.count >= 500, "TTS sample should be >= 500 bytes, got \(data.count)")
        #expect(data.count > 1000, "TTS sample should be substantial audio, got \(data.count)")
    }

    @Test("TTS sample has valid MP3 header")
    func ttsSampleValidFormat() throws {
        let url = try #require(testBundle.url(forResource: "tts_sample", withExtension: "mp3"))
        let data = try Data(contentsOf: url)
        let header = Array(data.prefix(3))

        // MP3 files start with 0xFF 0xFB (sync word) or ID3 tag header
        let isMP3SyncWord = header[0] == 0xFF && (header[1] & 0xE0) == 0xE0
        let isID3Tag = header[0] == 0x49 && header[1] == 0x44 && header[2] == 0x33  // "ID3"

        #expect(isMP3SyncWord || isID3Tag, "Should be valid MP3 format (got header: \(header.map { String(format: "%02X", $0) }.joined(separator: " ")))")
    }

    // MARK: - Silence File Tests

    @Test("Silence file is valid audio format")
    func silenceIsValidFormat() throws {
        let url = try #require(testBundle.url(forResource: "silence_1sec", withExtension: "m4a"))
        let data = try Data(contentsOf: url)

        // M4A files contain 'ftyp' marker in the header
        let headerString = String(data: data.prefix(12), encoding: .ascii) ?? ""
        #expect(headerString.contains("ftyp"), "Should have ftyp marker in M4A header")
    }

    @Test("Silence file meets minimum size threshold")
    func silenceFileValidSize() throws {
        let url = try #require(testBundle.url(forResource: "silence_1sec", withExtension: "m4a"))
        let data = try Data(contentsOf: url)

        // Silence file should be above the 500-byte rejection threshold
        #expect(data.count >= 500, "Silence file should be >= 500 bytes, got \(data.count)")
    }

    // MARK: - Too Short File Tests (Edge Case)

    @Test("Too short recording is rejected by size threshold")
    func tooShortRejected() throws {
        let url = try #require(testBundle.url(forResource: "too_short", withExtension: "m4a"))
        let data = try Data(contentsOf: url)

        // This file should be below the 500-byte rejection threshold
        #expect(data.count < 500, "Too short file should be < 500 bytes, got \(data.count)")
    }

    @Test("Too short file has valid M4A header structure")
    func tooShortHasValidHeader() throws {
        let url = try #require(testBundle.url(forResource: "too_short", withExtension: "m4a"))
        let data = try Data(contentsOf: url)

        // Even truncated M4A should have ftyp marker
        let headerString = String(data: data.prefix(8), encoding: .ascii) ?? ""
        #expect(headerString.contains("ftyp"), "Should have ftyp marker (mimics truncated recording)")
    }

    // MARK: - Size Threshold Validation

    @Test("500-byte threshold correctly classifies fixtures")
    func thresholdClassifiesFixtures() throws {
        let minimumValidSize = 500

        // TTS sample should pass
        let ttsUrl = try #require(testBundle.url(forResource: "tts_sample", withExtension: "mp3"))
        let ttsData = try Data(contentsOf: ttsUrl)
        #expect(ttsData.count >= minimumValidSize, "TTS should pass threshold")

        // Silence should pass
        let silenceUrl = try #require(testBundle.url(forResource: "silence_1sec", withExtension: "m4a"))
        let silenceData = try Data(contentsOf: silenceUrl)
        #expect(silenceData.count >= minimumValidSize, "Silence should pass threshold")

        // Too short should fail
        let tooShortUrl = try #require(testBundle.url(forResource: "too_short", withExtension: "m4a"))
        let tooShortData = try Data(contentsOf: tooShortUrl)
        #expect(tooShortData.count < minimumValidSize, "Too short should fail threshold")
    }
}

// MARK: - Bundle Token

/// Token class for locating the test bundle
private final class BundleToken {}
