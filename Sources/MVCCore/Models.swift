import Foundation
import CMVC

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
public struct MVCFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
