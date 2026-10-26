//
//  StreamUrlInput.swift
//  OpenImmersive
//
//  Created by Anthony Maës (Acute Immersive) on 10/17/24.
//

import SwiftUI

/// A button revealing a sheet with a `TextField` and a clipboard paste button for manual input of HLS stream URLs.
public struct StreamUrlInput: View {
    /// The visibility of the sheet.
    @State private var mvcFormat = false
    @State private var isSheetShowing: Bool = false
    /// The current value of the text field.
    @State private var textfieldRawVal: String = ""
    /// The cleaned up value of the text field.
    private var textfieldVal: String {
        get {
            textfieldRawVal.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    
    /// The URL validity of the current value of the text field. The "Load Stream" button is only active if this is `true`.
    ///
    /// The URL verification is very lenient and will mostly catch obvious accidental inputs.
    @State private var isUrlValid: Bool = false
    
    /// The callback to execute after a valid HLS stream URL has been submitted.
    var loadItemAction: VideoItemAction
    
    /// Public initializer for visibility.
    /// - Parameters:
    ///   - loadItemAction: the callback to execute after a file has been picked.
    public init(loadItemAction: @escaping VideoItemAction) {
        self.loadItemAction = loadItemAction
    }
    
    public var body: some View {
        Button("Enter Stream URL", systemImage: "link.circle.fill") {
            isSheetShowing.toggle()
        }
        .sheet(isPresented: $isSheetShowing) {
            VStack {
                HStack {
                    Button(role: .cancel) {
                        textfieldRawVal = ""
                        isSheetShowing = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonBorderShape(.circle)
                    
                    Text("Enter a stream or MVC MKV URL")
                        .font(.headline)
                        .padding()
                    
                    Spacer()
                }
                .padding()
                
                HStack {
                    TextField("Stream URL", text: $textfieldRawVal)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit {
                            loadStream()
                        }
                    
                    Button {
                        if let str = UIPasteboard.general.string {
                            textfieldRawVal = str
                        }
                    } label: {
                        Image(systemName: "list.clipboard")
                    }
                    .buttonBorderShape(.circle)
                }
                .padding()
                
                Toggle("MVC MKV (also for URLs without a file extension)", isOn: $mvcFormat)
                    .padding(.horizontal)

                HStack {
                    Button("Load Stream", systemImage: "play.rectangle.fill") {
                        loadStream()
                        isSheetShowing = false
                    }
                    .disabled(!isUrlValid)
                }
                .padding()
            }
            .padding()
            .interactiveDismissDisabled()
            .presentationBackground(.clear)
            .onChange(of: textfieldVal) { _, _ in
                isUrlValid = validateUrl() != nil
            }
        }
    }
    
    /// Validate that the text field value is a valid URL
    /// - Returns: a `URL` object for the text field value if the URL is valid, `nil` otherwise.
    ///
    /// The URL verification is very lenient and will mostly catch obvious accidental inputs.
    ///
    /// It checks that a `URL` object can be built from the text field string value,
    /// then checks that the resulting object has a host, which implicitly checks for scheme, domain, and basic syntax.
    private func validateUrl() -> URL? {
        guard let url = URL(string: textfieldVal),
              url.host() != nil,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        
        return url
    }
    
    /// Loads the HLS stream for playback.
    private func loadStream() {
        guard let url = validateUrl() else {
            return
        }
        
        let isMVC = mvcFormat || ["mkv", "mk3d"].contains(url.pathExtension.lowercased())
        let item = VideoItem(
            metadata: [
                .commonIdentifierTitle: isMVC ? url.lastPathComponent : "Stream",
                .commonIdentifierDescription: url.absoluteString,
            ],
            url: url,
            projection: isMVC ? .rectangular : nil,
            playbackEngine: mvcFormat ? .mvc : .automatic
        )
        
        loadItemAction(item)
    }
}

#Preview {
    StreamUrlInput() { _ in
        //nothing
    }
}
