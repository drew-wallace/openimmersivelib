import AVFoundation

extension VideoItem {
    static func selectedFile(_ url: URL, description: String) -> VideoItem {
        let projection: Projection?
        switch url.pathExtension.lowercased() {
        case "aivu": projection = .appleImmersive
        case "mkv", "mk3d": projection = .rectangular
        default: projection = nil
        }
        return VideoItem(metadata: [.commonIdentifierTitle: url.lastPathComponent,
                                    .commonIdentifierDescription: description],
                         url: url, projection: projection)
    }

    static func streamURL(from input: String) -> URL? {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.host != nil, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}
