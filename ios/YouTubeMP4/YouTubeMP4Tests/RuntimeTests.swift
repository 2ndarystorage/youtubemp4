import XCTest
import AVFoundation
@testable import YouTubeMP4

@MainActor
final class RuntimeTests: XCTestCase {
    private func fixture(_ name: String, extension ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
    }
    private func temporaryOutput() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    }
    private func source(_ name: String, video: Bool, audio: Bool, height: Int = 720, bitrate: Int = 100) -> MediaSource {
        MediaSource(url: URL(string: "https://example.test/\(name)")!, hasVideo: video,
                    hasAudio: audio, resolution: height, bitrate: bitrate)
    }

    func testRejectsHostSpoofingAndAcceptsSharedURLs() throws {
        XCTAssertEqual(try VideoStore.videoID(from: "https://youtu.be/abcdefghijk?si=share"), "abcdefghijk")
        XCTAssertEqual(try VideoStore.videoID(from: "https://www.youtube.com/shorts/abcdefghijk"), "abcdefghijk")
        XCTAssertThrowsError(try VideoStore.videoID(from: "https://youtube.com.evil.test/watch?v=abcdefghijk"))
        XCTAssertThrowsError(try VideoStore.videoID(from: "https://www.youtube.com/playlist?list=abc"))
    }

    func testSkipsSilentCandidateWhenNoSeparateAudioExists() {
        let silent = source("silent", video: true, audio: false, height: 1080)
        let combined = source("combined", video: true, audio: true, height: 720)
        let plans = DownloadPlanner.plans([silent, combined], maxHeight: 1080)
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.video.url, combined.url)
        XCTAssertNil(plans.first?.audio)
    }

    func testPrefersCombinedAtSameResolutionAndRetainsFallback() {
        let silent = source("separate", video: true, audio: false, bitrate: 1000)
        let audio = source("audio", video: false, audio: true, height: 0)
        let combined = source("combined", video: true, audio: true)
        let plans = DownloadPlanner.plans([silent, audio, combined], maxHeight: 720)
        XCTAssertEqual(plans.count, 2)
        XCTAssertEqual(plans[0].video.url, combined.url)
        XCTAssertEqual(plans[1].audio?.url, audio.url)
        XCTAssertTrue(DownloadPlanner.plans([combined], maxHeight: 360).isEmpty)
    }

    func testValidatesPlayableMovieAndRejectsSilentFile() async throws {
        let store = VideoStore()
        try await store.validateMovie(fixture("combined", extension: "mp4"))
        do {
            try await store.validateMovie(fixture("video", extension: "mp4"))
            XCTFail("A silent file must not be reported as a successful download")
        } catch { /* expected */ }
    }

    func testMergesRealVideoAndAudioIntoPlayableMP4() async throws {
        let output = temporaryOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        let store = VideoStore()
        try await store.merge(video: fixture("video", extension: "mp4"),
                              audio: fixture("audio", extension: "m4a"), to: output)
        try await store.validateMovie(output)
        let duration = try await AVURLAsset(url: output).load(.duration)
        XCTAssertEqual(duration.seconds, 3, accuracy: 0.15)
    }

    func testTrimsRealMovieAndPreservesAudio() async throws {
        let original = try fixture("combined", extension: "mp4")
        let output = temporaryOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        let asset = AVURLAsset(url: original)
        let session = try XCTUnwrap(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality))
        session.timeRange = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600),
                                       duration: CMTime(seconds: 1, preferredTimescale: 600))
        try await MP4Exporter.run(session, to: output)
        try await VideoStore().validateMovie(output)
        let duration = try await AVURLAsset(url: output).load(.duration)
        XCTAssertEqual(duration.seconds, 1, accuracy: 0.15)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testCancellingBeforeExportDoesNotCreateOutput() async throws {
        let asset = AVURLAsset(url: try fixture("combined", extension: "mp4"))
        let output = temporaryOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        let session = try XCTUnwrap(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality))
        let task = Task { try await MP4Exporter.run(session, to: output) }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled export must throw") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
