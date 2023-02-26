//
//  ContentView.swift
//  VideoMeta
//
//  Created by Frank Ye on 2023-01-26.
//

import SwiftUI
import AVKit

struct VideoInfoView: View {
    @AppStorage("lastOpenLocation") var lastOpenLocation: URL?
    @ObservedObject var appState: AppState
    
    var body: some View {
        GroupBox(label: Label("Video Info", systemImage: "video")) {
            HStack(alignment: .top) {
                Image(nsImage: appState.videoInfo.poster)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180.0, height: 240.0)
                    .border(.gray)
                    .dropDestination(for: Data.self) { items, position in
                        if (appState.videoInfo.asset == nil) { return false }
                        
                        guard let data = items.first else { return false }
                        guard let image = NSImage(data: data) else {return false }
                        appState.videoInfo.poster = image
                        return true
                    }
                VStack {
                    HStack {
                        TextField("Identifier", text: $appState.videoInfo.identifier).frame(width: 100)
                        TextField("Release Date", text: $appState.videoInfo.releaseDate).frame(width: 100)
                        Spacer()
                    }
                    TextField("Title", text: $appState.videoInfo.title)
                    TextField("Cast", text: $appState.videoInfo.cast)
                    TextField("Genre", text: $appState.videoInfo.genre)
                    ScrollView {
                        TextField("Description", text: $appState.videoInfo.description, axis: .vertical)
                            .lineLimit(50, reservesSpace: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxHeight: 70.0)
                    Spacer()
                    HStack {
                        Text(appState.subtitleFileName).disabled(true)
                        Spacer()
                        Text("Time Adjustment:")
                        TextField("Time Adjustment", text: $appState.subtitleTimeAdjustment).frame(width: 50)
                    }
                    HStack {
                        Toggle("Replace existing subtitle", isOn: $appState.replaceExistingSubtitle)
                            .disabled(appState.subtitleFileUrl == nil)
                        Spacer()
                        Button("Add Subtitle") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = false
                            panel.allowsMultipleSelection = false
                            if let srtType = UTType(filenameExtension: "srt") { panel.allowedContentTypes = [srtType] }
                            panel.allowsOtherFileTypes = true
                            panel.directoryURL = lastOpenLocation
                            panel.begin(completionHandler: { (response) in
                                if response == NSApplication.ModalResponse.OK {
                                    guard let subtitleUrl = panel.url else { return }
                                    appState.subtitleFileUrl = subtitleUrl

                                    let openLocation = subtitleUrl.deletingLastPathComponent()
                                    self.lastOpenLocation = openLocation
                                }
                            })
                        }
                    }
                }.frame(maxHeight: 300.0)
            }
        }
    }
}

struct ChaptersListView: View {
    @ObservedObject var appState: AppState

    private let timeFormatter = CMTimeFormatter()

    var body: some View {
        GroupBox(label: Label("Chapter Info", systemImage: "photo.on.rectangle")) {
            VStack {
                List($appState.videoInfo.chapters, selection: $appState.selectedChapterID) { $chapter in
                    HStack {
                        Image(nsImage: chapter.image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 120.0, height: 90.0)
                            .border(.gray)
                            .dropDestination(for: Data.self) { items, position in
                                guard let data = items.first else { return false }
                                guard let image = NSImage(data: data) else {return false }
                                chapter.image = image
                                return true
                            }
                        VStack {
                            TextField("time", value: $chapter.time, formatter: timeFormatter)
                                .disabled(true)
                            TextField("chapter title", text: $chapter.title)
                                .onSubmit {
                                    var genres: Set<String> = []
                                    if appState.videoInfo.genre.count > 0 {
                                        genres = genres.union(appState.videoInfo.genre.components(separatedBy: "/").map {
                                            return $0.trimmingCharacters(in: .whitespacesAndNewlines)
                                        })
                                    }
                                    for chapter in appState.videoInfo.chapters {
                                        if chapter.title.count > 0 {
                                            let chapterTitles = chapter.title.components(separatedBy: "/").map {
                                                return $0.trimmingCharacters(in: .whitespacesAndNewlines)
                                            }
                                            genres = genres.union(chapterTitles)
                                        }
                                    }
                                    appState.videoInfo.genre = genres.joined(separator: "/")
                                }
                            Toggle("Export", isOn: $chapter.keep)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
                Spacer()
                HStack {
                    Button("+", action: {
                        Task {
                            let time = appState.playbackTime
                            if let chapter = await appState.createChapter(at: time, with: "") {
                                DispatchQueue.main.async {
                                    // insert new chapter in sorted order
                                    let index = appState.videoInfo.chapters.firstIndex(where: { $0.time > time }) ?? appState.videoInfo.chapters.endIndex
                                    appState.videoInfo.chapters.insert(chapter, at: index)
                                }
                            }
                        }
                    }).disabled(appState.videoInfo.asset == nil)
                    Button("-", action: {
                        guard let index = appState.selectedChapterIndex else { return }
                        if index > 0 && index < appState.videoInfo.chapters.endIndex { appState.videoInfo.chapters.remove(at: index) }
                    }).disabled(appState.videoInfo.asset == nil || appState.selectedChapterID == nil || appState.selectedChapterIndex == 0)
                    Spacer()
                }
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack {
            ZStack {
                VideoPlayer(player: appState.player) {
                    if appState.videoInfo.asset != nil {
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .scaledToFill()
                            .draggable(appState.screenshotData, preview: {
                                Image(nsImage: appState.screenshotImage)
                            })
                    }
                    else {
                        Text("Please load a MP4 or MOV movie first")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .scaledToFill()
                    }
                }
                .disabled(appState.videoInfo.asset == nil || appState.exporting)

                if appState.exporting {
                    ProgressView(appState.exportMessage, value: appState.exportProgress)
                        .progressViewStyle(.linear)
                        .padding(50.0)
                        .background(appState.exportError ? .red : .blue)
                }
            }
            HStack {
                VideoInfoView(appState: appState).frame(maxHeight: .infinity)
                ChaptersListView(appState: appState).frame(width: 350).frame(maxHeight: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
            .disabled(appState.videoInfo.asset == nil || appState.exporting)
        }
        .padding()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var appState = AppState()
    static var previews: some View {
        ContentView(appState: appState)
    }
}
