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
    
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        Window("Video Meta", id: "main") {
            ContentView(appState: appState)
        }
        .commands {
            CommandGroup(before: .newItem) {
                Button("Open…", action: self.openCommand).keyboardShortcut("o")
                Button("Export…", action: self.exportCommand).keyboardShortcut("s").disabled(appState.videoInfo.asset == nil)
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
        appState.loadAsset(from: assetUrl)
        
        let openLocation = assetUrl.deletingLastPathComponent()
        self.lastOpenLocation = openLocation
    }
    
    private func exportCommand() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.canSelectHiddenExtension = true
        panel.isExtensionHidden = false
        panel.directoryURL = self.lastSaveLocation
        let title = appState.videoInfo.title.count > 0 ? appState.videoInfo.title : "Movie"
        let releaseYear = appState.videoInfo.releaseDate.count >= 4 ?
            String(appState.videoInfo.releaseDate.prefix(4)) :
            String(Calendar.current.component(.year, from: Date()))
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
        appState.exportProgress = 0.0
        appState.exportMessage = "Exporting ..."
        appState.exportError = false
        appState.exporting = true

        Task {
            let exporter = VideoExport(appState: appState)
            await exporter.export(to: exportUrl, progressHandler: updateExportProgress, completionHandler: markExportPAsComplete, errorHandler: notifyExportError)
        }

        let saveLocation = exportUrl.deletingLastPathComponent()
        self.lastSaveLocation = saveLocation
    }

    private func updateExportProgress(_ progress: Float) {
        appState.exportProgress = progress
    }

    private func markExportPAsComplete() {
        appState.exporting = false
    }

    private func notifyExportError(_ message: String) {
        appState.exportError = true
        appState.exportMessage = message
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { timer in
            appState.exporting = false
            timer.invalidate()
        }
    }
}
