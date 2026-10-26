//
//  AVMetadataIdentifier+Codable.swift
//  OpenImmersive
//
//  Created by Anthony Maës on 12/11/25.
//

import AVFoundation

/// Preserve the string representation used by previously serialized VideoItems.
extension AVMetadataIdentifier: @retroactive Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
