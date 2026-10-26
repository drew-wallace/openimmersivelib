//
//  FilePicker.swift
//  OpenImmersive
//
//  Created by Anthony Maës (Acute Immersive) on 10/17/24.
//

import SwiftUI
import UniformTypeIdentifiers

/// A button revealing a file importer configured to only allow the selection of videos.
public struct FilePicker: View {
    /// The visibility of the file importer.
    @State private var isFileImporterShowing = false
    
    /// The callback to execute after a file has been picked.
    var loadItemAction: VideoItemAction
    
    /// Public initializer for visibility.
    /// - Parameters:
    ///   - loadItemAction: the callback to execute after a file has been picked.
    public init(loadItemAction: @escaping VideoItemAction) {
        self.loadItemAction = loadItemAction
    }
    
    public var body: some View {
        Button("Open from Files", systemImage: "folder.fill") {
            isFileImporterShowing.toggle()
        }
        .fileImporter(
            isPresented: $isFileImporterShowing,
            allowedContentTypes: [.audiovisualContent, UTType(filenameExtension: "aivu")!,
                                  UTType(filenameExtension: "mkv") ?? .data,
                                  UTType(filenameExtension: "mk3d") ?? .data]
        ) { result in
            switch result {
            case .success(let url):
                // VideoPlayer owns security-scoped access for the playback lifetime.
                let isAivuFile = url.lastPathComponent.hasSuffix(".aivu")
                let isMVC = ["mkv", "mk3d"].contains(url.pathExtension.lowercased())
                let item = VideoItem(
                    metadata: [
                        .commonIdentifierTitle: url.lastPathComponent,
                        .commonIdentifierDescription: "From Local Files",
                    ],
                    url: url,
                    projection: isAivuFile ? .appleImmersive : (isMVC ? .rectangular : nil)
                )
                loadItemAction(item)
                break
                
            case .failure(let error):
                print("Error: failed to load file: \(error.localizedDescription)")
                break
            }
        }
    }
}

#Preview {
    FilePicker() { _ in
        // nothing
    }
}
