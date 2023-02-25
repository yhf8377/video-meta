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
        guard let assetUrl = url else { return }
        self.video.url = assetUrl
        
        let openLocation = assetUrl.deletingLastPathComponent()
        self.lastOpenLocation = openLocation
    }
    
    private func exportCommand() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.canSelectHiddenExtension = true
        panel.isExtensionHidden = false
        panel.directoryURL = self.lastSaveLocation
        let title = self.video.title.count > 0 ? self.video.title : "Movie"
        let releaseYear = self.video.releaseDate.count >= 4 ? String(self.video.releaseDate.prefix(4)) : String(Calendar.current.component(.year, from: Date()))
        panel.nameFieldStringValue = "\(title) (\(releaseYear)).mov"
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
        self.video.exportMessage = "Exporting ..."
        self.video.exportError = false
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
        self.video.exportError = true
        self.video.exportMessage = message
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { timer in
            self.video.exporting = false
            timer.invalidate()
        }
    }
}
