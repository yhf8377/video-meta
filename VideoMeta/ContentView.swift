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
    @ObservedObject var video: VideoInfo
    
    var body: some View {
        GroupBox(label: Label("Video Info", systemImage: "video")) {
            HStack(alignment: .top) {
                Image(nsImage: video.poster)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180.0, height: 240.0)
                    .border(.gray)
                    .dropDestination(for: Data.self) { items, position in
                        if (video.asset == nil) { return false }
                        
                        guard let data = items.first else { return false }
                        guard let image = NSImage(data: data) else {return false }
                        video.poster = image
                        return true
                    }
                VStack {
                    HStack {
                        TextField("Release Date", text: $video.releaseDate).frame(width: 100)
                        Spacer()
                    }
                    TextField("Title", text: $video.title)
                    TextField("Cast", text: $video.cast)
                    ScrollView {
                        TextField("Description", text: $video.description, axis: .vertical)
                            .lineLimit(50, reservesSpace: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxHeight: 120)
                    Spacer()
                    HStack {
                        Text(video.subtitleFileName)
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

                                    let openLocation = subtitleUrl.deletingLastPathComponent()
                                    self.lastOpenLocation = openLocation

                                    self.video.subtitleFileName = subtitleUrl.path()
                                }
                            })
                        }
                    }
                }
            }
        }
    }
}

struct ChaptersListView: View {
    @ObservedObject var video: VideoInfo

    private let timeFormatter = CMTimeFormatter()

    var body: some View {
        GroupBox(label: Label("Chapter Info", systemImage: "photo.on.rectangle")) {
            VStack {
                List($video.chapters, selection: $video.selectedChapterID) { $chapter in
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
                            Toggle("Export", isOn: $chapter.keep)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
                Spacer()
                HStack {
                    Button("+", action: {
                        let time = video.playbackTime
                        video.addChapter(at: time, with: "")
                    }).disabled(video.asset == nil)
                    Button("-", action: {
                        guard let index = video.selectedChapterIndex else { return }
                        if index > 0 { video.chapters.remove(at: index) }
                    }).disabled(video.asset == nil || video.selectedChapterIndex == nil || video.selectedChapterIndex == 0)
                    Spacer()
                }
            }.frame(maxHeight: .infinity)
        }
    }
}

struct ContentView: View {
    @ObservedObject var video: VideoInfo
    
    var body: some View {
        VStack {
            ZStack {
                VideoPlayer(player: video.player) {
                    if video.asset != nil {
                        Color.clear
                            .contentShape(Rectangle())
                            .scaledToFill()
                            .draggable(video.screenshotData, preview: {
                                Image(nsImage: video.screenshotImage)
                            })
                    }
                    else {
                        Text("Please load a MP4 or MOV movie first")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .scaledToFill()
                    }
                }
                .disabled(video.asset == nil || video.exporting)

                if video.exporting {
                    ProgressView(video.exportMessage, value: video.exportProgress)
                        .progressViewStyle(.linear)
                        .padding(50.0)
                        .background(video.exportError ? .red : .blue)
                }
            }
            HStack {
                VideoInfoView(video: video).frame(maxHeight: .infinity)
                ChaptersListView(video: video).frame(width: 350).frame(maxHeight: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
            .disabled(video.asset == nil || video.exporting)
        }
        .padding()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var video = VideoInfo()
    static var previews: some View {
        ContentView(video: video)
    }
}
