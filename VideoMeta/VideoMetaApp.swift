//
//  VideoMetaApp.swift
//  VideoMeta
//
//  Created by Frank Ye on 2023-01-26.
//

import SwiftUI
import AVKit

@main
struct VideoMetaApp: App {
    @AppStorage("lastOpenLocation") var lastOpenLocation: URL?
    @AppStorage("lastSaveLocation") var lastSaveLocation: URL?
    
    @StateObject private var video = VideoInfo()
    
    var body: some Scene {
        Window("Video Meta", id: "main") {
            ContentView(video: video)
        }
        .commands {
            CommandGroup(before: .newItem) {
                Button("Open…", action: self.openCommand).keyboardShortcut("o")
                Button("Export…", action: self.exportCommand).keyboardShortcut("s")//.disabled(self.video.asset == nil)
            }
        }
    }
    
    private func openCommand() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.directoryURL = lastOpenLocation
        panel.begin(completionHandler: { (response) in
            if response == NSApplication.ModalResponse.OK {
                loadVideo(from: panel.url)
            }
        })
    }
    
    private func loadVideo(from url: URL?) {
        self.video.url = url
        
        if var assetUrl = url {
            assetUrl.deleteLastPathComponent()
            self.lastOpenLocation = assetUrl
        }
    }
    
    private func exportCommand() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.canSelectHiddenExtension = true
        panel.isExtensionHidden = false
        panel.directoryURL = self.lastSaveLocation
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.begin(completionHandler: { (response) in
            if response == NSApplication.ModalResponse.OK {
                exportVideo(to: panel.url)
            }
        })
    }
    
    private func exportVideo(to url: URL?) {
        guard let exportUrl = url else { return }
        self.video.exportProgress = 0.0
        self.video.exporting = true
        
        Task {
            let exporter = VideoExport(video: self.video)
            await exporter.export(to: exportUrl, progressHandler: updateExportProgress, completionHandler: markExportPAsComplete, errorHandler: notifyExportError)
        }
        
        let saveLocation = exportUrl.deletingLastPathComponent()
        self.lastSaveLocation = saveLocation
    }

    private func updateExportProgress(_ progress: Float) {
        self.video.exportProgress = progress
    }

    private func markExportPAsComplete() {
        self.video.exporting = false
    }

    private func notifyExportError(_ message: String) {
        self.video.exporting = false
    }
}
