//
//  Video.swift
//  VideoMeta
//
//  Created by Frank Ye on 2023-01-26.
//

import Cocoa
import AVFoundation

extension Sequence {
    func asyncMap<T>(
        _ transform: (Element) async throws -> T
    ) async rethrows -> [T] {
        var values = [T]()

        for element in self {
            try await values.append(transform(element))
        }

        return values
    }
}

class CMTimeFormatter: Formatter {
    override func string(for obj: Any?) -> String? {
        guard let time = obj as? CMTime else { return nil }
        if time.isValid {
            let value = time.seconds
            let hours = Int(value / 3600)
            let minutes = Int((value - Double(hours) * 3600.0) / 60)
            let seconds = value - Double(hours) * 3600.0 - Double(minutes) * 60.0
            return String(format: "%.2d:%.2d:%04.1f", hours, minutes, seconds)
        } else {
            return nil
        }
    }

    func fromString(_ string: String) -> CMTime? {
        let components = string.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        if components.count == 3 {
            guard let hours = Double(components[0]) else { return nil }
            guard let minutes = Double(components[1]) else { return nil }
            guard let seconds = Double(components[2]) else { return nil }

            let time = CMTime(seconds: hours * 3600 + minutes * 60 + seconds, preferredTimescale: 1000)
            return time
        }
        else {
            return nil
        }
    }

    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
                                 for string: String, errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        if let value = fromString(string) {
            obj?.pointee = value as AnyObject
            return true
        }
        else {
            return false
        }
    }
}

struct Chapter: Identifiable {
    let id = UUID()
    var time: CMTime
    var title: String
    var image: NSImage
    var keep: Bool

    init(time: CMTime, title: String, image: NSImage, keep: Bool = true) {
        self.time = time
        self.title = title
        self.image = image
        self.keep = keep
    }
}

class VideoInfo: ObservableObject {
    init(url: URL? = nil) {
        self.url = url
        self.player = AVPlayer(playerItem: nil)

        self.player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC)), queue: .main) { [weak self] time in
            guard let me = self else { return }
            guard let item = me.player.currentItem else { return }
            me.playbackTime = item.currentTime()
        }
    }

    var url: URL? {
        didSet { self.updateVideoInfo(with: self.url) }
    }

    let player: AVPlayer!

    @Published var asset: AVAsset? = nil
    var playbackTime: CMTime = .zero {
        didSet {
            if self._screenshotTimer != nil { self._screenshotTimer?.invalidate() }
            self._screenshotTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { timer in
                if self._screenshotTime != self.playbackTime {
                    self._screenshotTime = self.playbackTime
                    self.takeScreenshot(at: self._screenshotTime) { data, image in
                        self._screenshotData = data
                        self._screenshotImage = image
                        self.objectWillChange.send()
                    }
                }
            }
        }
    }

    @Published var poster = NSImage()
    var releaseDate: String = ""
    var title: String = ""
    var cast: String = ""
    var description: String = ""

    private var _subtitleFileUrl: URL? = nil
    var subtitleFileUrl: URL? {
        get { return _subtitleFileUrl }
    }
    var subtitleFileName: String {
        get { return self._subtitleFileUrl != nil ? self._subtitleFileUrl!.lastPathComponent : "" }
        set {
            _subtitleFileUrl = URL(fileURLWithPath: newValue)
            self.objectWillChange.send()
        }
    }

    @Published var chapters: [Chapter] = []
    @Published var selectedChapterID: Chapter.ID? = nil {
        didSet {
            guard let index = self.selectedChapterIndex else { return }
            let time = self.chapters[index].time
            Task {
                self.player.seek(to: time)
            }
        }
    }
    var selectedChapterIndex: Int? {
        get { return self.findChapterIndex(for: self.selectedChapterID) }
    }

    private var _screenshotTime: CMTime = .invalid
    private var _screenshotTimer: Timer? = nil
    private var _screenshotData: Data? = nil
    private var _screenshotImage: NSImage? = nil
    var screenshotData: Data {
        get { return self._screenshotData != nil ? self._screenshotData! : Data() }
    }
    var screenshotImage: NSImage {
        get { return self._screenshotImage != nil ? self._screenshotImage! : NSImage() }
    }

    @Published var exporting: Bool = false
    @Published var exportError: Bool = false
    @Published var exportProgress: Float = 0.0
    @Published var exportMessage: String = "Exporting ..."

    func findChapterIndex(for id: Chapter.ID?) -> Int? {
        return id != nil ? chapters.firstIndex(where: { $0.id == id }) : nil
    }

    func addChapter(at time: CMTime, with title: String, and image: NSImage? = nil) {
        // do not insert duplicated chapters
        if self.chapters.contains(where: { abs($0.time.seconds - time.seconds) < 1.0 }) { return }
        // insert new chapter in sorted order
        let index = self.chapters.firstIndex(where: { $0.time > time })

        // take screenshot if one was not provided
        if image == nil {
            self.takeScreenshot(at: time) { data, image in
                let screenshot = image != nil ? image! : NSImage()
                let newChapter = Chapter(time: time, title: title, image: screenshot)
                self.chapters.insert(newChapter, at: index != nil ? index! : self.chapters.endIndex)
            }
        }
        else {
            let newChapter = Chapter(time: time, title: title, image: image!)
            self.chapters.insert(newChapter, at: index != nil ? index! : self.chapters.endIndex)
        }
    }

    private func asyncTakeScreenshot(at: CMTime? = nil) async -> (Data?, NSImage?) {
        guard let asset = self.asset else { return (nil, nil) }
        let time = at != nil ? at! : self.playbackTime

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 120.0, height: 90.0)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 1)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 1)

        var actualTime = CMTime.zero
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: &actualTime) else { return (nil, nil) }
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmapRep.representation(using: NSBitmapImageRep.FileType.jpeg, properties: [:]) else { return (nil, nil) }
        guard let image = NSImage(data: data) else { return (nil, nil) }
        return (data, image)
    }

    private func takeScreenshot(at time: CMTime, completionHandler: @escaping (Data?, NSImage?) -> Void) {
        Task {
            let (data, image) = await self.asyncTakeScreenshot(at: time)
            DispatchQueue.main.async { completionHandler(data, image) }
        }
    }

    private func updateVideoInfo(with assetUrl: URL?) {
        if self._screenshotTimer != nil {
            self._screenshotTimer?.invalidate()
            self._screenshotTimer = nil
        }
        self._screenshotTime = .invalid
        self._screenshotData = nil
        self._screenshotImage = nil
        self._subtitleFileUrl = nil

        if let url = assetUrl {
            let asset = AVAsset(url: url)
            let playerItem = AVPlayerItem(asset: asset)
            self.asset = asset
            self.player.replaceCurrentItem(with: playerItem)
            self.playbackTime = .zero
            self.takeScreenshot(at: .zero) { data, image in
                self._screenshotData = data
                self._screenshotImage = image
                self.objectWillChange.send()
            }
        }
        else {
            self.asset = nil
            self.player.replaceCurrentItem(with: nil)
            self.playbackTime = .zero
        }

        self.selectedChapterID = nil
        self.chapters = []

        Task {
            await self.asyncLoadVideoMetadata(from: self.asset)
            let chapters = await self.asyncLoadVideoChapters(from: self.asset)
            DispatchQueue.main.async {
                if chapters.count > 0 {
                    self.chapters = chapters
                }
                else {
                    self.addChapter(at: .zero, with: "")
                }
            }
        }
    }

    private func asyncLoadVideoMetadata(from anAsset: AVAsset?) async {
        guard let asset = anAsset else { return }
        do {
//            reference: https://blog.timroesner.com/metadata-from-avasset
//            keySpace: ‘itsk’
//                Name: ‘©nam’
//                Artwork: ‘covr’
//                Artist: ‘©ART’
//                Writer: ‘©wrt’
//                Description: ‘desc’
//                Long Description: ‘ldes’
//                Genres: ‘©gen’
//                Release date: ‘©day’
//                Executive Producers: ‘©xpd’
//                HD: ‘hdvd’
//                0: No
//                1: 720p
//                2: 1080p
//                Media type: ‘stik’
//                9: Movie
//            keySpace: ‘itlk’
//                Age rating: ‘com.apple.iTunes.iTunEXTC’
//                Cast, Directors, Screenwriters, and Studio (.plist): ‘com.apple.iTunes.iTunMOVI’
            let metadata = try await asset.loadMetadata(for: .iTunesMetadata)
            if let data = await self.getMetadataDataValue(from: metadata, with: AVMetadataKey("covr"), in: AVMetadataKeySpace("itsk")) {
                guard let image = NSImage(data: data) else { return }
                DispatchQueue.main.async { self.poster = image }
            }
            if let releaseDate = await self.getMetadataDateValue(from: metadata, with: AVMetadataKey("©day"), in: AVMetadataKeySpace("itsk")) {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                DispatchQueue.main.async { self.releaseDate = formatter.string(from: releaseDate) }
            }
            if let title = await self.getMetadataStringValue(from: metadata, with: AVMetadataKey("©nam"), in: AVMetadataKeySpace("itsk")) {
                DispatchQueue.main.async { self.title = title }
            }
            if let cast = await self.getMetadataStringValuesFromPropertyList(from: metadata, with: AVMetadataKey("com.apple.iTunes.iTunMOVI"), in: AVMetadataKeySpace("itlk"), using: "cast") {
                DispatchQueue.main.async { self.cast = cast.joined(separator: "/") }
            }
            if let description = await self.getMetadataStringValue(from: metadata, with: AVMetadataKey("ldes"), in: AVMetadataKeySpace("itsk")) {
                DispatchQueue.main.async { self.description = description }
            }
            DispatchQueue.main.async { self.objectWillChange.send() }
        }
        catch {
        }
    }

    private func asyncLoadVideoChapters(from anAsset: AVAsset?) async -> [Chapter] {
        guard let asset = anAsset else { return [] }
        do {
            guard let language = try await asset.load(.availableChapterLocales).first?.language.languageCode?.identifier else { return [] }
            let chapterGroups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: [language])
            return await chapterGroups.asyncMap { group in
                var chapter = Chapter(time: group.timeRange.start, title: "", image: NSImage())

                let titleItems = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle)
                if let title = try? await titleItems.first?.load(.stringValue) {
                    chapter.title = title
                }

                let artworkItems = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierArtwork)
                if let data = try? await artworkItems.first?.load(.dataValue), let image = NSImage(data: data) {
                    chapter.image = image
                }
                return chapter
            }
        }
        catch {
            return []
        }
    }

    private func getMetadataStringValue(from metadata: [AVMetadataItem], with key: AVMetadataKey, in keySpace: AVMetadataKeySpace) async -> String? {
        let metadataItem = AVMetadataItem.metadataItems(from: metadata, withKey: key, keySpace: keySpace)
        guard let item = metadataItem.first else { return nil }
        guard let value = try? await item.load(.stringValue) else { return nil }
        return value
    }

    private func getMetadataStringValuesFromPropertyList(from metadata: [AVMetadataItem], with key: AVMetadataKey, in keySpace: AVMetadataKeySpace, using subkey: String) async -> [String]? {
        let metadataItem = AVMetadataItem.metadataItems(from: metadata, withKey: key, keySpace: keySpace)
        guard let item = metadataItem.first else { return nil }
        guard let value = try? await item.load(.stringValue)?.data(using: .utf8) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: value, options: .mutableContainersAndLeaves, format: nil) as? [String:AnyObject] else { return nil }
        guard let values = plist[subkey].map({$0.value(forKey: "name")}) as? [String] else { return nil }
        return values
    }

    private func getMetadataDateValue(from metadata: [AVMetadataItem], with key: AVMetadataKey, in keySpace: AVMetadataKeySpace) async -> Date? {
        let metadataItem = AVMetadataItem.metadataItems(from: metadata, withKey: key, keySpace: keySpace)
        guard let item = metadataItem.first else { return nil }
        guard let value = try? await item.load(.dateValue) else { return nil }
        return value
    }

    private func getMetadataDataValue(from metadata: [AVMetadataItem], with key: AVMetadataKey, in keySpace: AVMetadataKeySpace) async -> Data? {
        let metadataItem = AVMetadataItem.metadataItems(from: metadata, withKey: key, keySpace: keySpace)
        guard let item = metadataItem.first else { return nil }
        guard let value = try? await item.load(.dataValue) else { return nil }
        return value
    }
}
