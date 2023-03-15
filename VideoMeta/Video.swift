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

struct VideoInfo {
    let url: URL?
    let asset: AVAsset?

    var poster = NSImage()
    var identifier: String = ""
    var releaseDate: String = ""
    var title: String = ""
    var cast: String = ""
    var genre: String = ""
    var description: String = ""

    var chapters: [Chapter] = []

    init() {
        self.url = nil
        self.asset = nil
    }

    init(url: URL) async {
        self.url = url
        self.asset = AVAsset(url: url)
        await load(asset: self.asset!)
    }

    func getChapter(at index: Int) -> Chapter? {
        return index >= self.chapters.startIndex && index < self.chapters.endIndex ? self.chapters[index] : nil
    }

    func getChapter(using id: Chapter.ID?) -> Chapter? {
        guard let index = self.chapters.firstIndex(where: { $0.id == id }) else { return nil }
        return getChapter(at: index)
    }

    private mutating func load(asset: AVAsset) async {
        self.poster = NSImage()
        self.identifier = ""
        self.releaseDate = ""
        self.title = ""
        self.cast = ""
        self.genre = ""
        self.description = ""

        await asyncLoadVideoMetadata(from: asset)
        self.chapters = await asyncLoadVideoChapters(from: asset)
    }

    private mutating func asyncLoadVideoMetadata(from asset: AVAsset) async {
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
//            let metadata = try await asset.loadMetadata(for: .iTunesMetadata)
            let metadata = try await asset.load(.metadata)
            if let data = await self.getMetadataDataValue(from: metadata, with: AVMetadataKey("covr"), in: AVMetadataKeySpace("itsk")) {
                guard let image = NSImage(data: data) else { return }
                self.poster = image
            }
            if let identifier = await self.getMetadataStringValue(from: metadata, with: .commonKeyIdentifier, in: .common) {
                self.identifier = identifier
            }
            if let releaseDate = await self.getMetadataDateValue(from: metadata, with: AVMetadataKey("©day"), in: AVMetadataKeySpace("itsk")) {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.timeZone = TimeZone(abbreviation: "UTC")
                self.releaseDate = formatter.string(from: releaseDate)
            }
            if let title = await self.getMetadataStringValue(from: metadata, with: AVMetadataKey("©nam"), in: AVMetadataKeySpace("itsk")) {
                self.title = title
            }
            if let cast = await self.getMetadataStringValuesFromPropertyList(from: metadata, with: AVMetadataKey("com.apple.iTunes.iTunMOVI"), in: AVMetadataKeySpace("itlk"), using: "cast") {
                self.cast = cast.joined(separator: "/")
            }
            if let genre = await self.getMetadataStringValue(from: metadata, with: .quickTimeMetadataKeyGenre, in: .quickTimeMetadata) {
                self.genre = genre
            }
            if let description = await self.getMetadataStringValue(from: metadata, with: AVMetadataKey("ldes"), in: AVMetadataKeySpace("itsk")) {
                self.description = description
            }
        }
        catch {
            print("Failed to load metadata from asset: \(error)")
        }
    }

    private mutating func asyncLoadVideoChapters(from asset: AVAsset) async -> [Chapter] {
        var chapters: [Chapter] = []
        do {
            guard let language = try await asset.load(.availableChapterLocales).first?.language.languageCode?.identifier else { return chapters }
            let chapterGroups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: [language])
            chapters = await chapterGroups.asyncMap { group in
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
            print("Failed to load chapters from asset: \(error)")
        }

        return chapters
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

@MainActor class AppState: ObservableObject {
    let player: AVPlayer
    @Published var videoInfo: VideoInfo

    @Published var selectedChapterID: Chapter.ID? = nil {
        didSet {
            guard let chapter = self.videoInfo.getChapter(using: self.selectedChapterID) else { return }
            Task {
                self.player.seek(to: chapter.time)
            }
        }
    }
    var selectedChapterIndex: Int? {
        get { return self.videoInfo.chapters.firstIndex(where: { return $0.id == self.selectedChapterID }) }
    }

    var playbackTime: CMTime = .zero {
        didSet { takeScreenshot(at: self.playbackTime, after: 0.5) }
    }

    private var _screenshotTimer: Timer? = nil
    private var _screenshotTime: CMTime = .invalid
    @Published private var _screenshotImage: NSImage? = nil
    var screenshotData: Data {
        get { return self.screenshotImage.jpegRepresentation() ?? Data() }
    }
    var screenshotImage: NSImage {
        get { return self._screenshotImage ?? NSImage() }
    }

    @Published var subtitleFileUrl: URL? = nil {
        didSet {
            self.replaceExistingSubtitle = true
            self.subtitleTimeAdjustment = "0.0"
        }
    }
    var subtitleFileName: String {
        get { return self.subtitleFileUrl != nil ? self.subtitleFileUrl!.lastPathComponent : "<no subtitle file>" }
        set { self.subtitleFileUrl = URL(fileURLWithPath: newValue, isDirectory: false) }
    }
    @Published var replaceExistingSubtitle: Bool = false
    @Published var subtitleTimeAdjustment: String = "0.0"
    var subtitleTimeAdjustmentValue: CMTime {
        get {
            let formatter = NumberFormatter()
            let value = formatter.number(from: subtitleTimeAdjustment)
            return value != nil ? CMTime(seconds: Double(truncating: value!), preferredTimescale: 1) : .zero
        }
    }

    @Published var exporting: Bool = false
    @Published var exportError: Bool = false
    @Published var exportProgress: Float = 0.0
    @Published var exportMessage: String = "Exporting ..."

    init() {
        self.videoInfo = VideoInfo()
        self.player = AVPlayer(playerItem: nil)
        self.player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC)), queue: .main) { [weak self] time in
            guard let me = self else { return }
            guard let item = me.player.currentItem else { return }
            me.playbackTime = item.currentTime()
        }
    }

    func loadAsset(from url: URL) {
        if self._screenshotTimer != nil {
            self._screenshotTimer?.invalidate()
            self._screenshotTimer = nil
        }
        self._screenshotTime = .invalid
        self._screenshotImage = nil

        self.subtitleFileUrl = nil
        self.replaceExistingSubtitle = false
        self.subtitleTimeAdjustment = "0.0"

        self.selectedChapterID = nil

        Task {
            var videoInfo = await VideoInfo(url: url)
            if videoInfo.chapters.count == 0 {
                let screenshot = await self.asyncTakeScreenshot(from: videoInfo.asset, at: .zero) ?? NSImage()
                let chapter = Chapter(time: .zero, title: "", image: screenshot)
                videoInfo.chapters.append(chapter)
            }

            DispatchQueue.main.async {
                self.videoInfo = videoInfo

                if let asset = self.videoInfo.asset {
                    let playerItem = AVPlayerItem(asset: asset)
                    self.player.replaceCurrentItem(with: playerItem)
                    self.playbackTime = .zero
                }
            }
        }
    }

    func createChapter(at time: CMTime, with title: String, and image: NSImage? = nil) async -> Chapter? {
        // do not insert duplicated chapters
        if self.videoInfo.chapters.contains(where: { abs($0.time.seconds - time.seconds) < 1.0 }) { return nil }

        // take screenshot if one was not provided
        if image == nil {
            let screenshot = await self.asyncTakeScreenshot(from: self.videoInfo.asset, at: time) ?? NSImage()
            return Chapter(time: time, title: title, image: screenshot)
        }
        else {
            return Chapter(time: time, title: title, image: image!)
        }
    }

    private func takeScreenshot(at time: CMTime, after delay: TimeInterval) {
        if self._screenshotTimer != nil {
            self._screenshotTimer?.invalidate()
            self._screenshotTimer = nil
        }

        if time != self._screenshotTime {
            self._screenshotTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { timer in
                Task {
                    let image = await self.asyncTakeScreenshot(from: self.videoInfo.asset, at: time)
                    DispatchQueue.main.async {
                        self._screenshotTime = time
                        self._screenshotImage = image
                    }
                }
            }
        }
    }

    private func asyncTakeScreenshot(from asset: AVAsset?, at time: CMTime) async -> NSImage? {
        if asset == nil { return nil }

        let generator = AVAssetImageGenerator(asset: asset!)
        let imageSize = CGSize(width: 120.0, height: 90.0)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = imageSize
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 1)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 1)

        var actualTime = CMTime.zero
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: &actualTime) else { return nil }
        return NSImage(cgImage: cgImage, size: imageSize)
    }
}
