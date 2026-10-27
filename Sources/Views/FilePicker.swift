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
                // The player owns access for the playback lifetime.
                let item = VideoItem.selectedFile(url, description: "From Local Files")
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
