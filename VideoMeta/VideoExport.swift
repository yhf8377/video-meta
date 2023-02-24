//
//  VideoExport.swift
//  VideoMeta
//
//  Created by Frank Ye on 2023-02-09.
//

import Foundation
import Cocoa
import AVFoundation

extension Data {
    func toBlockBuffer() -> CMBlockBuffer? {
        var blockBuffer: CMBlockBuffer? = nil
        let bufferLength = self.count

        // allocate memory for block buffer
        if kCVReturnSuccess != CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                                  memoryBlock: nil,
                                                                  blockLength: bufferLength,
                                                                  blockAllocator: kCFAllocatorDefault,
                                                                  customBlockSource: nil,
                                                                  offsetToData: 0,
                                                                  dataLength: bufferLength,
                                                                  flags: 0,
                                                                  blockBufferOut: &blockBuffer)
            || blockBuffer == nil { return nil }

        // copy data into block buffer
        // this is less efficient than referencing the memory itself
        // but since we are only using this for a few text and static images and there is no real-time processing, it is okay
        // I did this to make sure freeing the Data object will not cause use-after-free issues
        if kCMBlockBufferNoErr != CMBlockBufferAssureBlockMemory(blockBuffer!) { return nil }
        if kCMBlockBufferNoErr != CMBlockBufferReplaceDataBytes(with: (self as NSData).bytes,
                                                                blockBuffer: blockBuffer!,
                                                                offsetIntoDestination: 0,
                                                                dataLength: bufferLength) { return nil }

        return blockBuffer
    }
}

extension NSImage {
    func jpegRepresentation() -> Data? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = bitmapRep.representation(using: NSBitmapImageRep.FileType.jpeg, properties: [:]) else { return nil }
        return jpegData
    }
}

enum VideoExportError: Error {
    case invalidAsset
    case failedCreatingNewMovie
    case failedLoadingAssetProperty
    case failedCreatingNewTrack
    case failedCreatingFormatDescription
    case failedPreparingSampleData
    case failedCreatingBlockBuffer
    case failedCreatingSampleBuffer
    case unknownError
}

actor VideoExport {
    private var _videoInfo: VideoInfo

    init(video: VideoInfo) {
        self._videoInfo = video
    }

    func export(to exportUrl: URL, progressHandler: (@MainActor (Float) -> Void)? = nil, completionHandler: (@MainActor () -> Void)? = nil, errorHandler: (@MainActor (String) -> Void)? = nil) async {
        do {
            // remove destination file if already exists
            if FileManager.default.fileExists(atPath: exportUrl.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: exportUrl)
            }

            // create movie objects
            guard let assetUrl = _videoInfo.url else { throw VideoExportError.invalidAsset }
            let sourceMovie = AVMovie(url: assetUrl, options: [AVURLAssetPreferPreciseDurationAndTimingKey : true])
            try sourceMovie.writeHeader(to: exportUrl, fileType: .mov, options: .truncateDestinationToMovieHeaderOnly)
            guard let newMovie = try? AVMutableMovie(settingsFrom: sourceMovie, options: [AVURLAssetPreferPreciseDurationAndTimingKey : true]) else { throw VideoExportError.failedCreatingNewMovie }
            newMovie.defaultMediaDataStorage = AVMediaDataStorage(url: exportUrl)

            // prepare metadata
            newMovie.metadata = prepareMetadata(from: _videoInfo)

            // find important tracks to keep
            var sourceTracks: [AVMovieTrack] = []
            var newTracks: [AVMutableMovieTrack] = []
            guard let (tracks, sourceDuration) = try? await sourceMovie.load(.tracks, .duration) else { throw VideoExportError.failedLoadingAssetProperty }
            for track in tracks {
                guard let format = try await track.load(.formatDescriptions).first else { throw VideoExportError.failedLoadingAssetProperty }
                let keep = (format.mediaType == .video && format.mediaSubType != .jpeg) || (format.mediaType == .audio) || (format.mediaType == .subtitle)
                if keep {
                    guard let newTrack = newMovie.addMutableTrack(withMediaType: track.mediaType, copySettingsFrom: track) else { throw VideoExportError.failedCreatingNewTrack }
                    sourceTracks.append(track)
                    newTracks.append(newTrack)
                }
            }

            // process chapter definitions
            if _videoInfo.chapters.count > 1 {
                guard let videoTrack = try? await newMovie.loadTracks(withMediaType: .video).first else { throw VideoExportError.failedCreatingNewTrack }

                guard let chapterTrack = newMovie.addMutableTrack(withMediaType: .text, copySettingsFrom: nil) else { throw VideoExportError.failedCreatingNewTrack }
                guard let thumbnailTrack = newMovie.addMutableTrack(withMediaType: .video, copySettingsFrom: nil) else { throw VideoExportError.failedCreatingNewTrack }

                var newTimeline: CMTime = .zero
                for (index, chapter) in _videoInfo.chapters.enumerated() {
                    let nextChapter = (index < _videoInfo.chapters.count-1 ? _videoInfo.chapters[index+1] : nil)
                    let chapterDuration = (nextChapter != nil ? nextChapter!.time - chapter.time : sourceDuration - chapter.time)
                    if chapter.keep {
                        let timeRange = CMTimeRange(start: newTimeline, duration: chapterDuration)
                        newTimeline = newTimeline + chapterDuration

                        // insert matching time range from source movie
                        for (index, sourceTrack) in sourceTracks.enumerated() {
                            let newTrack = newTracks[index]
                            try newTrack.insertTimeRange(timeRange, of: sourceTrack, at: timeRange.start, copySampleData: true)
                        }

                        // add chapter track
                        try await appendChapterSample(to: chapterTrack, for: chapter, on: timeRange)
                        try await appendThumbnailSample(to: thumbnailTrack, for: chapter, on: timeRange)

                        // update export progress
                        let progress = Float((chapter.time + chapterDuration).seconds / sourceDuration.seconds)
                        await progressHandler?(progress)
                    }
                }

                chapterTrack.insertMediaTimeRange(CMTimeRange(start: .zero, duration: newTimeline), into: CMTimeRange(start: .zero, duration: newTimeline))
                thumbnailTrack.insertMediaTimeRange(CMTimeRange(start: .zero, duration: newTimeline), into: CMTimeRange(start: .zero, duration: newTimeline))

                videoTrack.addTrackAssociation(to: chapterTrack, type: .chapterList)
                videoTrack.addTrackAssociation(to: thumbnailTrack, type: .chapterList)

                chapterTrack.isEnabled = false
                thumbnailTrack.isEnabled = false
            }
            else {
                try newMovie.insertTimeRange(CMTimeRange(start: .zero, duration: sourceDuration), of: sourceMovie, at: .zero, copySampleData: true)
            }

            try newMovie.writeHeader(to: exportUrl, fileType: .mov, options: .addMovieHeaderToDestination)
            await completionHandler?()
        }
        catch {
            print("Export error: \(error)")
            await errorHandler?(error.localizedDescription)
        }
    }

    private func appendChapterSample(to track: AVMutableMovieTrack, for chapter: Chapter, on timeRange: CMTimeRange) async throws {
        guard let formatDesc = try? createTextFormatDescription() else { throw VideoExportError.failedCreatingFormatDescription }
        guard let sampleData = try? createSampleData(from: chapter.title) else { throw VideoExportError.failedPreparingSampleData }
        try appendNewSample(from: sampleData, format: formatDesc, timing: timeRange, to: track)
    }

    private func appendThumbnailSample(to track: AVMutableMovieTrack, for chapter: Chapter, on timeRange: CMTimeRange) async throws {
        guard let formatDesc = try? createJpegFormatDescription(for: chapter.image) else { throw VideoExportError.failedCreatingFormatDescription }
        guard let sampleData = try? createSampleData(from: chapter.image) else { throw VideoExportError.failedPreparingSampleData }
        try appendNewSample(from: sampleData, format: formatDesc, timing: timeRange, to: track)
    }

private func appendNewSample(from sampleData: Data, format sampleFormat: CMFormatDescription, timing timeRange: CMTimeRange, to track: AVMutableMovieTrack) throws {
    guard let blockBuffer = sampleData.toBlockBuffer() else {
        throw VideoExportError.failedCreatingSampleBuffer
    }
    var blockBufferLength = CMBlockBufferGetDataLength(blockBuffer)

    var sampleTiming = CMSampleTimingInfo(duration: timeRange.duration,
                                          presentationTimeStamp: timeRange.start,
                                          decodeTimeStamp: .invalid)

    // create sample buffer
    var sampleBuffer: CMSampleBuffer? = nil
    if kCVReturnSuccess != CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: sampleFormat,
        sampleCount: 1,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &sampleTiming,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &blockBufferLength,
        sampleBufferOut: &sampleBuffer) || sampleBuffer == nil { throw VideoExportError.failedCreatingSampleBuffer }

    try track.append(sampleBuffer!, decodeTime: nil, presentationTime: nil)
}

    private func createTextFormatDescription() throws -> CMFormatDescription? {
        // prepare sample description (reference: https://developer.apple.com/library/archive/documentation/QuickTime/QTFF/QTFFChap3/qtff3.html#//apple_ref/doc/uid/TP40000939-CH205-BBCJAJEA)
        let textDescription: Array<UInt8> = [
            0x00, 0x00, 0x00, 0x3C,                         // 32-bit size (total sample description size 60 bytes)
            0x74, 0x65, 0x78, 0x74,                         // 32-bit sample type ('text')
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,             // 48-bit reserved
            0x00, 0x01,                                     // 16-bit data reference index
            0x00, 0x00, 0x00, 0x01,                         // 32-bit display flags
            0x00, 0x00, 0x00, 0x01,                         // 32-bit text justification
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,             // 48-bit background color
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 64-bit default text box
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 64-bit reserved
            0x00, 0x00,                                     // 16-bit font number
            0x00, 0x00,                                     // 16-bit font face
            0x00,                                           // 8-bit reserved
            0x00, 0x00,                                     // 16-bit reserved
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,             // 48-bit foreground color
            0x00                                            // null-terminated text name
        ]

        var formatDesc: CMTextFormatDescription? = nil
        try textDescription.withUnsafeBytes() { ptr in
            if kCVReturnSuccess != CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(allocator: kCFAllocatorDefault,
                                                                                                 bigEndianTextDescriptionData: ptr.baseAddress!,
                                                                                                 size: textDescription.count,
                                                                                                 flavor: nil,
                                                                                                 mediaType: kCMMediaType_Text,
                                                                                                 formatDescriptionOut: &formatDesc) { throw VideoExportError.failedCreatingFormatDescription }
        }
        return formatDesc
    }

    private func createJpegFormatDescription(for image: NSImage) throws -> CMFormatDescription? {
        // reference: https://developer.apple.com/library/archive/documentation/QuickTime/QTFF/QTFFChap3/qtff3.html#//apple_ref/doc/uid/TP40000939-CH205-BBCGICBJ
        var jpegDescription: Array<UInt8> = [
            0x00, 0x00, 0x00, 0x56,                         // 32-bit size (total sample description size 60 bytes)
            0x6A, 0x70, 0x65, 0x67,                         // 32-bit sample type ('jpeg')
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,             // 48-bit reserved
            0x00, 0x00,                                     // 16-bit data reference index
            0x00, 0x00,                                     // 16-bit version number
            0x00, 0x00,                                     // 16-bit revision level
            0x00, 0x00, 0x00, 0x00,                         // 32-bit vendor code
            0x00, 0x00, 0x00, 0x00,                         // 32-bit temporal quality
            0x00, 0x00, 0x00, 0x00,                         // 32-bit spatial quality
            0x07, 0x80,                                     // 16-bit width (e.g. 1920)
            0x04, 0x38,                                     // 16-bit height (e.g. 1080)
            0x00, 0x48, 0x00, 0x00,                         // 32-bit horizontal resolution
            0x00, 0x48, 0x00, 0x00,                         // 32-bit vertical resolution
            0x00, 0x00, 0x00, 0x00,                         // 32-bit data size
            0x00, 0x01,                                     // 16-bit frame count (e.g. 1)
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 32-byte null-terminated string for compressor name (e.g. 'jpeg')
            0x00, 0x18,                                     // 16-bit color depth (e.g. 24)
            0xFF, 0xFF                                      // 16-bit color table ID (e.g. -1 for default color table)
        ]

        // update image size in sample description based on actual image size
        let size = image.size
        if size.width > CGFloat(UInt16.max) || size.height > CGFloat(UInt16.max) { throw VideoExportError.failedCreatingFormatDescription }
        let widthBigEndian = CFSwapInt16HostToBig(UInt16(size.width))
        let heightBigEndian = CFSwapInt16HostToBig(UInt16(size.height))

        try jpegDescription.withUnsafeMutableBytes { ptr in
            guard let destPtr = ptr.baseAddress else { throw VideoExportError.failedCreatingFormatDescription }
            withUnsafePointer(to: widthBigEndian) { srcPtr in destPtr.advanced(by: 32).copyMemory(from: srcPtr, byteCount: MemoryLayout<UInt16>.size) }
            withUnsafePointer(to: heightBigEndian) { srcPtr in destPtr.advanced(by: 34).copyMemory(from: srcPtr, byteCount: MemoryLayout<UInt16>.size) }
        }

        var formatDesc: CMVideoFormatDescription? = nil
        try jpegDescription.withUnsafeBytes() { ptr in
            if kCVReturnSuccess != CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData(allocator: kCFAllocatorDefault,
                                                                                                   bigEndianImageDescriptionData: ptr.baseAddress!,
                                                                                                   size: jpegDescription.count,
                                                                                                   stringEncoding: CFStringGetSystemEncoding(),
                                                                                                   flavor: nil,
                                                                                                   formatDescriptionOut: &formatDesc) { throw VideoExportError.failedCreatingFormatDescription }
        }
        return formatDesc
    }

    private func createSampleData(from text: String) throws -> Data {
        struct TextEncodingModifierAtom {
            let size: UInt32
            let type: UInt32
            let encoding: UInt32

            init(_ encoding: UInt32) {
                self.size = CFSwapInt32HostToBig(UInt32(MemoryLayout<TextEncodingModifierAtom>.size))
                self.type = CFSwapInt32HostToBig(0x656E6364)
                self.encoding = CFSwapInt32HostToBig(encoding)
            }
        }
        let encodingAtom = TextEncodingModifierAtom(0x08000100)     // kCFStringEncodingUTF8 = 0x08000100

        guard let utf8Data = text.data(using: .utf8) else { throw VideoExportError.failedPreparingSampleData }
        let dataLengthBigEndian = CFSwapInt16HostToBig(UInt16(utf8Data.count))

        // block buffer size is a 16-bit integer (size) plus the legnth of the text (without terminating null-byte) and the encoding modifier atom
        let dataOffset = MemoryLayout<UInt16>.size
        let atomOffset = MemoryLayout<UInt16>.size + utf8Data.count
        let bufferLength = MemoryLayout<UInt16>.size + utf8Data.count + MemoryLayout<TextEncodingModifierAtom>.size
        if (bufferLength > UInt16.max) { throw VideoExportError.failedCreatingBlockBuffer }

        // construct sample data
        var sampleData = Data(count: bufferLength)
        sampleData.replaceSubrange(dataOffset..<atomOffset, with: utf8Data)
        sampleData.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: dataLengthBigEndian, as: UInt16.self)
            ptr.storeBytes(of: encodingAtom, toByteOffset: atomOffset, as: TextEncodingModifierAtom.self)
        }

        return sampleData
    }

    private func createSampleData(from image: NSImage) throws -> Data {
        guard let jpegData = image.jpegRepresentation() else { throw VideoExportError.failedPreparingSampleData }
        return jpegData
    }

    private func prepareMetadata(from video: VideoInfo) -> [AVMetadataItem] {
        var metadata: [AVMetadataItem] = []

        // metadata for poster
        if video.poster.size.width > 0 && video.poster.size.height > 0 {
            metadata.append(createMetadata(for: .commonIdentifierArtwork, in: .common, using: .commonKeyArtwork, with: video.poster))
            metadata.append(createMetadata(for: .iTunesMetadataCoverArt, in: .iTunes, using: .iTunesMetadataKeyCoverArt, with: video.poster))
            metadata.append(createMetadata(for: AVMetadataIdentifier("itsk/covr"), in: AVMetadataKeySpace("itsk"), using: AVMetadataKey("covr"), with: video.poster))
        }

        // metadata for release date
        if video.releaseDate.count > 0 {
            metadata.append(createMetadata(for: .commonIdentifierCreationDate, in: .common, using: .commonKeyCreationDate, with: video.releaseDate))
            metadata.append(createMetadata(for: .iTunesMetadataReleaseDate, in: .iTunes, using: .iTunesMetadataKeyReleaseDate, with: video.releaseDate))
            metadata.append(createMetadata(for: AVMetadataIdentifier("itsk/©day"), in: AVMetadataKeySpace("itsk"), using: AVMetadataKey("©day"), with: video.releaseDate))
        }

        // metadata for title
        if video.title.count > 0 {
            metadata.append(createMetadata(for: .commonIdentifierTitle, in: .common, using: .commonKeyTitle, with: video.title))
            metadata.append(createMetadata(for: .iTunesMetadataSongName, in: .iTunes, using: .iTunesMetadataKeySongName, with: video.title))
            metadata.append(createMetadata(for: AVMetadataIdentifier("itsk/©nam"), in: AVMetadataKeySpace("itsk"), using: AVMetadataKey("©nam"), with: video.title))
        }

        // metadata for cast
        if video.cast.count > 0 {
            metadata.append(createMetadata(for: .commonIdentifierArtist, in: .common, using: .commonKeyArtist, with: video.cast))
            metadata.append(createMetadata(for: .iTunesMetadataArtist, in: .iTunes, using: .iTunesMetadataKeyArtist, with: video.cast))
            metadata.append(createMetadata(for: AVMetadataIdentifier("itlk/com.apple.iTunes.iTunMOVI"), in: AVMetadataKeySpace("itlk"), using: AVMetadataKey("com.apple.iTunes.iTunMOVI"), with: mergeCastMembersIntoPropertyList(from: video)))
        }

        // metadata for description
        if video.description.count > 0 {
            metadata.append(createMetadata(for: .commonIdentifierDescription, in: .common, using: .commonKeyDescription, with: video.description))
            metadata.append(createMetadata(for: .iTunesMetadataDescription, in: .iTunes, using: .iTunesMetadataKeyDescription, with: video.description))
            metadata.append(createMetadata(for: AVMetadataIdentifier("itsk/ldes"), in: AVMetadataKeySpace("itsk"), using: AVMetadataKey("ldes"), with: video.description))
        }

        // metadata for genres
        let genres = mergeChapterTitles(from: _videoInfo.chapters)
        if genres.count > 0 {
            metadata.append(createMetadata(for: .iTunesMetadataUserGenre, in: .iTunes, using: .iTunesMetadataKeyUserGenre, with: genres))
            metadata.append(createMetadata(for: AVMetadataIdentifier("itsk/©gen"), in: AVMetadataKeySpace("itsk"), using: AVMetadataKey("©gen"), with: genres))
        }

        return metadata
    }

    private func mergeChapterTitles(from chapters: [Chapter]) -> String {
        var genres: Set<String> = []
        for chapter in chapters {
            let chapterTitles = chapter.title.components(separatedBy: "/").map { return $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            genres = genres.union(chapterTitles)
        }
        return genres.joined(separator: "/")
    }

    private func mergeCastMembersIntoPropertyList(from video: VideoInfo) -> String {
        let cast = video.cast.components(separatedBy: "/").map {
            let dict: Dictionary<String,String> = ["name": $0.trimmingCharacters(in: .whitespacesAndNewlines)]
            return dict
        }
        let plist: Dictionary<String,Array<Dictionary<String,String>>> = ["cast": cast]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return "" }
        guard let xml = String(data: data, encoding: .utf8) else { return "" }
        return xml
    }

    private func createMetadata(for identifier: AVMetadataIdentifier, in space: AVMetadataKeySpace, using key: AVMetadataKey, with stringValue: String) -> AVMutableMetadataItem {
        let metaItem = AVMutableMetadataItem()
        metaItem.keySpace = space
        metaItem.key = key as NSString
        metaItem.identifier = identifier
        metaItem.value = stringValue as NSString
        return metaItem
    }

    private func createMetadata(for identifier: AVMetadataIdentifier, in space: AVMetadataKeySpace, using key: AVMetadataKey, with imageValue: NSImage) -> AVMutableMetadataItem {
        let metaItem = AVMutableMetadataItem()
        metaItem.keySpace = space
        metaItem.key = key as NSString
        metaItem.identifier = identifier
        let data = imageValue.jpegRepresentation() as? NSData
        metaItem.value = data != nil ? data! : NSData()
        return metaItem
    }
}
