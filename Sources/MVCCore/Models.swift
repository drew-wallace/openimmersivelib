import Foundation
import CMVC
import Darwin

func thermalName() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
}

public enum MediaSource: Sendable {
    case local(URL)
    case http(URL)
    public var displayName: String {
        switch self { case .local(let url), .http(let url): return url.lastPathComponent }
    }
    public var transport: String { if case .http = self { return "HTTP" }; return "Local" }
}
public enum PlaybackState: String, Codable, Sendable {
    case idle, opening, buffering, playing, paused, seeking, ended, failed
}
public struct AudioTrack: Identifiable, Codable, Sendable {
    public let id: Int
    public let codec: String
    public let language: String
    public let title: String
    public let channels: Int
    public let sampleRate: Int
    public var label: String { "\(language.isEmpty ? "und" : language) · \(codec) · \(channels) ch\(title.isEmpty ? "" : " · " + title)" }
}
public struct MediaInfo: Codable, Sendable {
    public let width: Int, height: Int
    public let fps: Double, duration: Double
    public let fullRange: Bool
    public let colorPrimaries: Int, colorTransfer: Int, colorMatrix: Int
    public let sampleAspectRatio: Double
    public let baseIsRight: Bool
    public let audioTracks: [AudioTrack]
    init(_ value: MVCMediaInfo) {
        width = Int(value.width); height = Int(value.height); fps = value.fps; duration = value.duration
        fullRange = value.full_range != 0
        colorPrimaries = Int(value.color_primaries); colorTransfer = Int(value.color_transfer); colorMatrix = Int(value.color_matrix)
        sampleAspectRatio = Double(value.sar_num) / Double(max(1, value.sar_den))
        baseIsRight = value.base_is_right != 0
        var tuple = value.audio
        audioTracks = withUnsafePointer(to: &tuple) { p in
            p.withMemoryRebound(to: MVCAudioTrack.self, capacity: 32) { tracks in
                (0..<Int(value.audio_count)).map { i in
                    var track = tracks[i]
                    return AudioTrack(id: Int(track.index), codec: cString(&track.codec), language: cString(&track.language),
                                      title: cString(&track.title), channels: Int(track.channels), sampleRate: Int(track.sample_rate))
                }
            }
        }
    }
}
func cString<T>(_ value: inout T) -> String {
    withUnsafePointer(to: &value) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
    }
}
public struct PlaybackDiagnostics: Codable, Sendable {
    public var schemaVersion = 1
    public var createdAt = Date()
    public var platform = ProcessInfo.processInfo.operatingSystemVersionString
    public var environment: String = {
        #if targetEnvironment(simulator)
        return "visionOS simulator"
        #elseif os(visionOS)
        return "visionOS device"
        #else
        return "macOS"
        #endif
    }()
    public var hardware: String = {
        var size = 0
        #if os(visionOS)
        let key = "hw.machine"
        #else
        let key = "hw.model"
        #endif
        guard sysctlbyname(key, nil, &size, nil, 0) == 0 else { return "unknown" }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: value)
    }()
    public var dependencies = String(cString: mvc_versions())
    public var transport = ""
    public var media: MediaInfo?
    public var stereoConfirmed = false
    public var decodedPairs = 0
    public var presentedPairs = 0
    public var droppedPairs = 0
    public var concealedPairs = 0
    public var bufferEvents = 0
    public var playbackState = "idle"
    public var playbackPositionSeconds: Double = 0
    public var renderedAudioChannels = 0
    public var audioTimingGaps = 0
    public var maxAudioTimingGapMicroseconds: Double = 0
    public var rendererErrors: [String] = []
    public var workerThreads = 4
    public var decodeAndCopySeconds: Double = 0
    public var decodeWallSeconds: Double = 0
    public var averageDecodeFPS: Double { decodeWallSeconds > 0 ? Double(decodedPairs) / decodeWallSeconds : 0 }
    public var thermalState = "unknown"
    public var validationNote = "Decoded/presented counters do not measure compositor drops or acoustic A/V sync. Hardware acceptance requires the documented external tests."
    public init() {}
    public func json() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
public struct MVCFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
