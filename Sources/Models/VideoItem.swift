//
//  VideoItem.swift
//  OpenImmersive
//
//  Created by Anthony Maës (Acute Immersive) on 9/25/24.
//

import AVFoundation

/// Simple structure describing a video.
public struct VideoItem: Codable {
    nonisolated public enum PlaybackEngine: String, Codable, Hashable, Sendable {
        /// MKV/MK3D use MVC; other URLs retain AVFoundation playback.
        case automatic
        case avFoundation
        /// Also use for extensionless, seekable HTTP MVC resources.
        case mvc
    }

    nonisolated
    public enum Projection: Codable, Hashable {
        /// Spherical projection of an equirectangular (or half equirectangular) frame. Use this for mono or MV-HEVC stereo VR180 & VR360 video.
        /// - Parameters:
        ///   - fieldOfView: the horizontal field of view of the video, in degrees.
        ///   - force: if false, use the field of view encoded in the media (only for local MV-HEVC). If true, use the provided `fieldOfView` no matter what (default false).
        case equirectangular(fieldOfView: Float, force: Bool = false)
        /// Rectangular video. Use this for 2D video and Spatial Video.
        case rectangular
        /// Native rendering for Apple Immersive Video (AIVU).
        case appleImmersive
    }
    
    nonisolated
    public enum FramePacking: Codable, Hashable {
        /// The video doesn't use frame packing. Use this for mono and MV-HEVC stereo videos (Spatial, AIV, some APMP).
        case none
        /// Left eye and right eye are packed side-by-side in each video frame. Common with legacy stereo VR180.
        /// - Parameters:
        ///   - baseline: the distance between the centers of the lenses of the stereo camera system, in millimeters. The default value is 60.0mm (Canon Dual Fisheye Lens).
        ///   - horizontalDisparity: the relative horizontal shift of the left and right images, which changes the zero parallax plane, in the uniform range [-1.0...1.0]. The default value is 0.
        case sideBySide(baseline: Float? = nil, horizontalDisparity: Float? = nil)
        /// Left eye and right eye are packed on top of one another in each video frame. Common with legacy stereo VR360.
        /// - Parameters:
        ///   - baseline: the distance between the centers of the lenses of the stereo camera system, in millimeters. The default value is 60.0mm (Canon Dual Fisheye Lens).
        ///   - horizontalDisparity: the relative horizontal shift of the left and right images, which changes the zero parallax plane, in the uniform range [-1.0...1.0]. The default value is 0.   
        case overUnder(baseline: Float? = nil, horizontalDisparity: Float? = nil)
    }
    
    /// Dictionary of metadata values for the video. `commonIdentifierTitle` and `commonIdentifierDescription` are expected.
    public var metadata: [AVMetadataIdentifier: String]
    /// URL to a media, whether local or streamed from a HLS server (m3u8).
    public var url: URL
    /// The projection type of the media (will default to 180.0 degree equirectangular if nil).
    public var projection: Projection?
    /// The frame packing type of the media (default to .none).
    public var framePacking: FramePacking
    public var playbackEngine: PlaybackEngine

    /// Resolves engine selection without network requests or AVAsset probing.
    public var usesMVC: Bool {
        playbackEngine == .mvc || (playbackEngine == .automatic &&
            ["mkv", "mk3d"].contains(url.pathExtension.lowercased()))
    }

    
    /// Public initializer for visibility.
    /// - Parameters:
    ///   - metadata: dictionary of metadata values for the video. `commonIdentifierTitle` and `commonIdentifierDescription` are expected.
    ///   - url: URL to a media, whether local or streamed from a HLS server (m3u8).
    ///   - projection: the projection type of the media (default nil).
    ///   - framePacking: the frame packing type of the media (default .none)
    public init(metadata: [AVMetadataIdentifier: String], url: URL, projection: Projection? = nil, framePacking: FramePacking = .none, playbackEngine: PlaybackEngine = .automatic) {
        self.metadata = metadata
        self.url = url
        self.projection = projection
        self.framePacking = framePacking
        self.playbackEngine = playbackEngine
    }
    private enum CodingKeys: String, CodingKey {
        case metadata, url, projection, framePacking, playbackEngine
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try values.decode([AVMetadataIdentifier: String].self, forKey: .metadata)
        url = try values.decode(URL.self, forKey: .url)
        projection = try values.decodeIfPresent(Projection.self, forKey: .projection)
        framePacking = try values.decodeIfPresent(FramePacking.self, forKey: .framePacking) ?? .none
        playbackEngine = try values.decodeIfPresent(PlaybackEngine.self, forKey: .playbackEngine) ?? .automatic
    }

}

extension VideoItem: Identifiable {
    public var id: String { url.absoluteString }
}

extension VideoItem: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension VideoItem: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

public extension VideoItem.FramePacking {
    /// Left eye and right eye are packed side-by-side in each video frame. Common with legacy stereo VR180.
    /// Assumes a disparity of 60mm.
    static let sideBySide: VideoItem.FramePacking = .sideBySide()
    
    /// Left eye and right eye are packed on top of one another in each video frame. Common with legacy stereo VR360.
    /// Assumes a disparity of 60mm.
    static let overUnder: VideoItem.FramePacking = .overUnder()
}
