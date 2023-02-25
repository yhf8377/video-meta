//
//  SubtitleAdapter.swift
//  VideoMeta
//
//  Created by Frank Ye on 2023-02-24.
//

import Foundation
import CoreMedia

struct SubtitleLine {
    var startTime: CMTime
    var endTime: CMTime
    var text: String
    
    var duration: CMTime {
        get { return endTime - startTime }
    }

    init(startTime: CMTime, endTime: CMTime, text: String) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

protocol SubtitleParser {
    func parseContents(_ contents: String) -> [SubtitleLine]
    func getLines(for timeRange: CMTimeRange) -> [SubtitleLine]
    func getLines(for timeRange: CMTimeRange, withOffset offset: CMTime) -> [SubtitleLine]
}

class Subtitle: SubtitleParser {
    private var _lines: [SubtitleLine] = []

    init(with fileUrl: URL) {
        guard let contents = try? String(contentsOf: fileUrl) else { return }
        _lines = parseContents(contents)
    }

    init(with contents: String) {
        _lines = parseContents(contents)
    }

    func parseContents(_ contents: String) -> [SubtitleLine] {
        return []
    }

    func getLines(for timeRange: CMTimeRange) -> [SubtitleLine] {
        return getLines(for: timeRange, withOffset: .zero)
    }

    func getLines(for timeRange: CMTimeRange, withOffset offset: CMTime) -> [SubtitleLine] {
        var lines: [SubtitleLine] = []
        for var subtitle in _lines {
            let subtitleRange = CMTimeRange(start: subtitle.startTime, end: subtitle.endTime).intersection(timeRange)
            if subtitleRange.duration > .zero {
                subtitle.startTime = subtitleRange.start + offset
                subtitle.endTime = subtitleRange.end + offset
                lines.append(subtitle)
            }
        }
        return lines
    }
}

class SRTSubtitle: Subtitle {
    // This is a very rough parser for the SRT format
    // TODO: Create a better version of SRT parser
    override func parseContents(_ fileContents: String) -> [SubtitleLine] {
        var lines: [SubtitleLine] = []
        var contents = fileContents

        let pattern = /\n*(\d+)\n(\d{2}:\d{2}:\d{2},\d{3})\s+-->\s+(\d{2}:\d{2}:\d{2},\d{3})\n(.+)\n/
        let formatter = CMTimeFormatter()
        while contents.count > 0 {
            if let match = contents.firstMatch(of: pattern) {
                // remove matched section from buffer
                contents = contents.replacing(pattern, maxReplacements: 1, with: { _ in return "" })
                
                guard let startTime = formatter.fromString("\(match.2)") else { continue }
                guard let endTime = formatter.fromString("\(match.3)") else { continue }
                let text = "\(match.4)"
                let subtitleLine = SubtitleLine(startTime: startTime, endTime: endTime, text: text)
                lines.append(subtitleLine)
            }
            else {
                break
            }
        }
        return lines
    }
}
