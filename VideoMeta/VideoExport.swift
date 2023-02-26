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
    case failedCreatingExportSession
    case unknownError
}

actor VideoExport {
    private var _appState: AppState

    init(appState: AppState) {
        self._appState = appState
    }

    func export(to exportUrl: URL, progressHandler: (@MainActor (Float) -> Void)? = nil, completionHandler: (@MainActor () -> Void)? = nil, errorHandler: (@MainActor (String) -> Void)? = nil) async {
        do {
            let videoInfo = await _appState.videoInfo

            // create temporary storage
            let temporaryUrl = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: temporaryUrl.path(), contents: nil)
            defer {
                try? FileManager.default.removeItem(at: temporaryUrl)
            }

            // prepare new movie
            let newMovie = try await prepareNewMovie(at: temporaryUrl)

            // remove destination file if already exists
            if FileManager.default.fileExists(atPath: exportUrl.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: exportUrl)
            }

            // export new movie
            guard let exportSession = AVAssetExportSession(asset: newMovie, presetName: AVAssetExportPresetPassthrough) else { throw VideoExportError.failedCreatingExportSession }
            exportSession.outputURL = exportUrl
            exportSession.outputFileType = .mov
            exportSession.shouldOptimizeForNetworkUse = true
            exportSession.canPerformMultiplePassesOverSourceMediaData = true
            exportSession.metadata = await prepareMetadata(from: videoInfo)

            let progressTimer = Timer(timeInterval: 0.5, repeats: true) { timer in
                switch exportSession.status {
                case .exporting:
                    DispatchQueue.main.async { progressHandler?(exportSession.progress) }
                case .failed:
                    DispatchQueue.main.async { errorHandler?("Export session failed with unknown reason") }
                default:
                    return
                }
            }
            RunLoop.main.add(progressTimer, forMode: .common)

            await exportSession.export()
            progressTimer.invalidate()

            DispatchQueue.main.async { progressHandler?(1.0) }
            DispatchQueue.main.async { completionHandler?() }
        }
        catch {
            print("Export error: \(error)")
            DispatchQueue.main.async { errorHandler?(error.localizedDescription) }
        }
    }

    private func prepareNewMovie(at temporaryUrl: URL) async throws -> AVMutableMovie {
        let videoInfo = await _appState.videoInfo
        let subtitleFileUrl = await _appState.subtitleFileUrl
        let replaceExistingSubtitle = await _appState.replaceExistingSubtitle
        let subtitleTimeAdjustmentValue = await _appState.subtitleTimeAdjustmentValue

        // create movie objects
        guard let assetUrl = videoInfo.url else { throw VideoExportError.invalidAsset }
        let sourceMovie = AVMutableMovie(url: assetUrl, options: [AVURLAssetPreferPreciseDurationAndTimingKey : true])
        guard let (tracks, sourceDuration) = try? await sourceMovie.load(.tracks, .duration) else { throw VideoExportError.failedLoadingAssetProperty }

        guard let newMovie = try? AVMutableMovie(settingsFrom: sourceMovie, options: [AVURLAssetPreferPreciseDurationAndTimingKey : true]) else { throw VideoExportError.failedCreatingNewMovie }
        newMovie.defaultMediaDataStorage = AVMediaDataStorage(url: temporaryUrl)

        // find important tracks to keep
        var sourceTracks: [AVMovieTrack] = []
        var newTracks: [AVMutableMovieTrack] = []
        for track in tracks {
            guard let format = try await track.load(.formatDescriptions).first else { throw VideoExportError.failedLoadingAssetProperty }
            let keep = (format.mediaType == .video && format.mediaSubType != .jpeg) ||
                       (format.mediaType == .audio) ||
                       (format.mediaType == .subtitle && (!replaceExistingSubtitle || subtitleFileUrl == nil))
            if keep {
                guard let newTrack = newMovie.addMutableTrack(withMediaType: track.mediaType, copySettingsFrom: track) else { throw VideoExportError.failedCreatingNewTrack }
                switch track.mediaType {
                case .audio:
                    newTrack.alternateGroupID = 1
                case .subtitle:
                    newTrack.alternateGroupID = 2
                default:
                    newTrack.alternateGroupID = 0
                }
                sourceTracks.append(track)
                newTracks.append(newTrack)
            }
        }

        // only produce chapter tracks when there are more than just the default chapter that was created automatically
        guard let videoTrack = try? await newMovie.loadTracks(withMediaType: .video).first else { throw VideoExportError.failedCreatingNewTrack }
        var chapterTrack: AVMutableMovieTrack? = nil
        var thumbnailTrack: AVMutableMovieTrack? = nil
        if videoInfo.chapters.count > 1 {
            chapterTrack = newMovie.addMutableTrack(withMediaType: .text, copySettingsFrom: nil)
            thumbnailTrack = newMovie.addMutableTrack(withMediaType: .video, copySettingsFrom: nil)
            if chapterTrack == nil || thumbnailTrack == nil { throw VideoExportError.failedCreatingNewTrack }
        }

        // only produce subtitle tracks when a new subtitle file was specified
        var subtitleTrack: AVMutableMovieTrack? = nil
        var subtitleParser: SubtitleParser? = nil
        if subtitleFileUrl != nil {
            subtitleTrack = newMovie.addMutableTrack(withMediaType: .subtitle, copySettingsFrom: nil)
            if subtitleTrack == nil { throw VideoExportError.failedCreatingNewTrack }
            subtitleTrack?.alternateGroupID = 2

            subtitleParser = try SRTSubtitle(fileUrl: subtitleFileUrl!, timeAdjust: subtitleTimeAdjustmentValue)
            let pattern = /[-_ ]([a-z]{2}-[A-Z]{2})\.srt/       // match patterns like 'en-US' at the end of the file name
            if let match = subtitleFileUrl!.path().firstMatch(of: pattern) {
                subtitleTrack?.extendedLanguageTag = "\(match.1)"
            }
        }

        // process chapter definitions
        var newTimeline: CMTime = .zero
        for (index, chapter) in videoInfo.chapters.enumerated() {
            let nextChapter = (index < videoInfo.chapters.count-1 ? videoInfo.chapters[index+1] : nil)
            let chapterDuration = (nextChapter != nil ? nextChapter!.time - chapter.time : sourceDuration - chapter.time)
            if chapter.keep || videoInfo.chapters.count <= 1 {
                let oldRange = CMTimeRange(start: chapter.time, duration: chapterDuration)
                let newRange = CMTimeRange(start: newTimeline, duration: chapterDuration)

                // insert matching time range from source movie
                for (index, sourceTrack) in sourceTracks.enumerated() {
                    let newTrack = newTracks[index]
                    try newTrack.insertTimeRange(oldRange, of: sourceTrack, at: newRange.start, copySampleData: false)
                }

                // add to chapter track
                if chapterTrack != nil { try await appendChapterSample(to: chapterTrack!, for: chapter, on: newRange) }
                if thumbnailTrack != nil { try await appendThumbnailSample(to: thumbnailTrack!, for: chapter, on: newRange) }

                // add to subtitle track
                if subtitleTrack != nil && subtitleParser != nil {
                    let offset = newRange.start - oldRange.start
                    let subtitleLines = subtitleParser!.getLines(for: oldRange, withOffset: offset)
                    var empty = SubtitleLine(startTime: newRange.start, endTime: newRange.end, text: "")
                    if subtitleLines.count > 0 {
                        for (index, line) in subtitleLines.enumerated() {
                            empty.endTime = line.startTime
                            // fill leading gap with an empty sample
                            try await appendSubtitleSample(to: subtitleTrack!, for: empty, on: CMTimeRange(start: empty.startTime, end: empty.endTime))
                            // write current subtitle line sample
                            try await appendSubtitleSample(to: subtitleTrack!, for: line, on: CMTimeRange(start: line.startTime, end: line.endTime))
                            empty.startTime = line.endTime
                            if (index == subtitleLines.endIndex - 1) {
                                // fill trailing gap with an empty sample
                                empty.endTime = newRange.end
                                try await appendSubtitleSample(to: subtitleTrack!, for: empty, on: CMTimeRange(start: empty.startTime, end: empty.endTime))
                            }
                        }
                    }
                    else {
                        // when no subtitle line was found for current chapter range, fill entire range with an empty sample
                        try await appendSubtitleSample(to: subtitleTrack!, for: empty, on: CMTimeRange(start: empty.startTime, end: empty.endTime))
                    }
                }

                // ready timeline for next iteration
                newTimeline = newTimeline + chapterDuration
            }
        }

        if chapterTrack != nil {
            chapterTrack!.insertMediaTimeRange(CMTimeRange(start: .zero, duration: newTimeline), into: CMTimeRange(start: .zero, duration: newTimeline))
            videoTrack.addTrackAssociation(to: chapterTrack!, type: .chapterList)
            chapterTrack!.isEnabled = false
        }

        if thumbnailTrack != nil {
            thumbnailTrack!.insertMediaTimeRange(CMTimeRange(start: .zero, duration: newTimeline), into: CMTimeRange(start: .zero, duration: newTimeline))
            videoTrack.addTrackAssociation(to: thumbnailTrack!, type: .chapterList)
            thumbnailTrack!.isEnabled = false
        }

        if subtitleTrack != nil {
            subtitleTrack!.insertMediaTimeRange(CMTimeRange(start: .zero, duration: newTimeline), into: CMTimeRange(start: .zero, duration: newTimeline))
        }

        return newMovie
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

    private func appendSubtitleSample(to track: AVMutableMovieTrack, for subtitle: SubtitleLine, on timeRange: CMTimeRange) async throws {
        guard let formatDesc = try? createSubtitleFormatDescription() else { throw VideoExportError.failedCreatingFormatDescription }
        guard let sampleData = try? createSampleData(from: subtitle) else { throw VideoExportError.failedPreparingSampleData }
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

    private func createSubtitleFormatDescription() throws -> CMFormatDescription? {
        // prepare sample description (reference: https://developer.apple.com/library/archive/documentation/QuickTime/QTFF/QTFFChap3/qtff3.html#//apple_ref/doc/uid/TP40000939-CH205-BBCJAJEA)
        let subtitleDescription: Array<UInt8> = [
            0x00, 0x00, 0x00, 0x40,                         // 32-bit size (total sample description size 64 bytes)
            0x74, 0x78, 0x33, 0x67,                         // 32-bit sample type ('tx3g')
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,             // 48-bit reserved
            0x00, 0x01,                                     // 16-bit data reference index
            0x20, 0x00, 0x00, 0x00,                         // 32-bit display flags
            0x00,                                           // 8-bit reserved (must set to 1)
            0xFF,                                           // 8-bit reserved (must set to -1)
            0x00, 0x00, 0x00, 0x00,                         // 32-bit reserved (must set to 0)
            0x03, 0x96, 0x00, 0x00, 0x04, 0x38, 0x07, 0x80, // 64-bit default text box
            0x00, 0x00, 0x00, 0x00,                         // 32-bit reserved (must set to 0)
            0x00, 0x01,                                     // 16-bit font number
            0x00,                                           // 8-bit font face
            0x18,                                           // 8-bit font size
            0xFF, 0xFF, 0xFF, 0xFF,                         // 32-bit foreground color
            // Font Table Atom
            0x00, 0x00, 0x00, 0x12,                         // 32-bit size (font table atom size 18 bytes)
            0x66, 0x74, 0x61, 0x62,                         // 32-bit atom type ('ftab')
            0x00, 0x01,                                     // 16-bit count (must be 1)
            0x00, 0x01,                                     // 16-bit font identifier
            0x05,                                           // 8-bit font name length
            0x41, 0x72, 0x69, 0x61, 0x6C                    // font name ('Arial')
        ]

        var formatDesc: CMTextFormatDescription? = nil
        try subtitleDescription.withUnsafeBytes() { ptr in
            if kCVReturnSuccess != CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(allocator: kCFAllocatorDefault,
                                                                                                 bigEndianTextDescriptionData: ptr.baseAddress!,
                                                                                                 size: subtitleDescription.count,
                                                                                                 flavor: nil,
                                                                                                 mediaType: kCMMediaType_Subtitle,
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

    private func createSampleData(from subtitle: SubtitleLine) throws -> Data {
        guard let utf8Data = subtitle.text.data(using: .utf8) else { throw VideoExportError.failedPreparingSampleData }
        let dataLengthBigEndian = CFSwapInt16HostToBig(UInt16(utf8Data.count))

        // block buffer size is a 16-bit integer (size) plus the legnth of the text (without terminating null-byte) and the encoding modifier atom
        let dataOffset = MemoryLayout<UInt16>.size
        let bufferLength = MemoryLayout<UInt16>.size + utf8Data.count
        if (bufferLength > UInt16.max) { throw VideoExportError.failedCreatingBlockBuffer }

        // construct sample data
        var sampleData = Data(count: bufferLength)
        sampleData.replaceSubrange(dataOffset..<bufferLength, with: utf8Data)
        sampleData.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: dataLengthBigEndian, as: UInt16.self)
        }

        return sampleData
    }

    private func prepareMetadata(from video: VideoInfo) async -> [AVMetadataItem] {
        var metadata: [AVMetadataItem] = []
        let videoInfo = await _appState.videoInfo

        // metadata for poster
        if video.poster.size.width > 0 && video.poster.size.height > 0 {
            metadata.append(createMetadata(for: .commonIdentifierArtwork, in: .common, using: .commonKeyArtwork, with: video.poster))
            metadata.append(createMetadata(for: .quickTimeMetadataArtwork, in: .quickTimeMetadata, using: .quickTimeMetadataKeyArtwork, with: video.poster))
            metadata.append(createMetadata(for: .iTunesMetadataCoverArt, in: .iTunes, using: .iTunesMetadataKeyCoverArt, with: video.poster))
            metadata.append(createMetadata(for: AVMetadataIdentifier("itsk/covr"), in: AVMetadataKeySpace("itsk"), using: AVMetadataKey("covr"), with: video.poster))
        }

        // metadata for movie identifier
        if video.identifier.count > 0 {
            metadata.append(createMetadata(for: .commonIdentifierAssetIdentifier, in: .common, using: .commonKeyIdentifier, with: video.identifier))
            metadata.append(createMetadata(for: .quickTimeMetadataContentIdentifier, in: .quickTimeMetadata, using: .quickTimeMetadataKeyContentIdentifier, with: video.identifier))
            metadata.append(createMetadata(for: .iTunesMetadataSongID, in: .iTunes, using: .iTunesMetadataKeySongID, with: video.identifier))
        }

        // metadata for release date
        if video.releaseDate.count > 0 {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy'-'MM'-'dd"
            formatter.timeZone = TimeZone(abbreviation: "UTC")
            if let date = formatter.date(from: video.releaseDate) {
                metadata.append(createMetadata(for: .commonIdentifierCreationDate, in: .common, using: .commonKeyCreationDate, with: date))
                metadata.append(createMetadata(for: .quickTimeMetadataYear, in: .quickTimeMetadata, using: .quickTimeMetadataKeyYear, with: date))
                metadata.append(createMetadata(for: .iTunesMetadataReleaseDate, in: .iTunes, using: .iTunesMetadataKeyReleaseDate, with: date))
                metadata.append(createMetadata(for: AVMetadataIdentifier("itsk/©day"), in: AVMetadataKeySpace("itsk"), using: AVMetadataKey("©day"), with: date))
            }
        }

        // metadata for title
        if video.title.count > 0 {
            metadata.append(createMetadata(for: .commonIdentifierTitle, in: .common, using: .commonKeyTitle, with: video.title))
            metadata.append(createMetadata(for: .quickTimeMetadataTitle, in: .quickTimeMetadata, using: .quickTimeMetadataKeyTitle, with: video.title))
            metadata.append(createMetadata(for: .iTunesMetadataSongName, in: .iTunes, using: .iTunesMetadataKeySongName, with: video.title))
            metadata.append(createMetadata(for: AVMetadataIdentifier("itsk/©nam"), in: AVMetadataKeySpace("itsk"), using: AVMetadataKey("©nam"), with: video.title))
        }

        // metadata for cast
        if video.cast.count > 0 {
            metadata.append(createMetadata(for: .commonIdentifierArtist, in: .common, using: .commonKeyArtist, with: video.cast))
            metadata.append(createMetadata(for: .quickTimeMetadataArtist, in: .quickTimeMetadata, using: .quickTimeMetadataKeyArtist, with: video.cast))
            metadata.append(createMetadata(for: .iTunesMetadataArtist, in: .iTunes, using: .iTunesMetadataKeyArtist, with: video.cast))
            metadata.append(createMetadata(for: AVMetadataIdentifier("itlk/com.apple.iTunes.iTunMOVI"), in: AVMetadataKeySpace("itlk"), using: AVMetadataKey("com.apple.iTunes.iTunMOVI"), with: mergeCastMembersIntoPropertyList(from: video)))
        }

        // metadata for description
        if video.description.count > 0 {
            metadata.append(createMetadata(for: .commonIdentifierDescription, in: .common, using: .commonKeyDescription, with: video.description))
            metadata.append(createMetadata(for: .quickTimeMetadataDescription, in: .quickTimeMetadata, using: .quickTimeMetadataKeyDescription, with: video.description))
            metadata.append(createMetadata(for: .iTunesMetadataDescription, in: .iTunes, using: .iTunesMetadataKeyDescription, with: video.description))
            metadata.append(createMetadata(for: AVMetadataIdentifier("itsk/ldes"), in: AVMetadataKeySpace("itsk"), using: AVMetadataKey("ldes"), with: video.description))
        }

        // metadata for genres
        let genres = videoInfo.genre
        if genres.count > 0 {
            metadata.append(createMetadata(for: .quickTimeMetadataGenre, in: .quickTimeMetadata, using: .quickTimeMetadataKeyGenre, with: genres))
            metadata.append(createMetadata(for: .iTunesMetadataUserGenre, in: .iTunes, using: .iTunesMetadataKeyUserGenre, with: genres))
            metadata.append(createMetadata(for: AVMetadataIdentifier("itsk/©gen"), in: AVMetadataKeySpace("itsk"), using: AVMetadataKey("©gen"), with: genres))
        }

        return metadata
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

    private func createMetadata(for identifier: AVMetadataIdentifier, in space: AVMetadataKeySpace, using key: AVMetadataKey, with dateValue: Date) -> AVMutableMetadataItem {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(abbreviation: "UTC")

        let metaItem = AVMutableMetadataItem()
        metaItem.keySpace = space
        metaItem.key = key as NSString
        metaItem.identifier = identifier
        metaItem.value = formatter.string(from: dateValue) as NSString
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
