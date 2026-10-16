import Foundation

struct MediaSample {
    var timeMS: UInt32
    var compositionMS: Int
    var keyframe: Bool
    var video: Bool
    var payload: Data
}

struct TSSegment {
    var index: Int
    var duration: Double
    var data: Data
}

enum MPEGTS {
    static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                if (crc & 0x80000000) != 0 { crc = (crc << 1) ^ 0x04C11DB7 }
                else { crc &<<= 1 }
            }
        }
        return crc
    }

    static func psiPacket(pid: UInt16, section: [UInt8], continuity: UInt8) -> [UInt8] {
        var packet = [UInt8](repeating: 0xFF, count: 188)
        packet[0] = 0x47
        packet[1] = 0x40 | UInt8((pid >> 8) & 0x1F)
        packet[2] = UInt8(pid & 0xFF)
        packet[3] = 0x10 | (continuity & 0x0F)
        var payload: [UInt8] = [0x00]
        payload.append(contentsOf: section)
        let crc = crc32(section)
        payload.append(contentsOf: [UInt8((crc >> 24) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)])
        let count = min(payload.count, 184)
        packet.replaceSubrange(4..<(4 + count), with: payload.prefix(count))
        return packet
    }

    static func pat(continuity: UInt8) -> [UInt8] {
        psiPacket(pid: 0, section: [0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xF0, 0x00], continuity: continuity)
    }

    static func pmt(video: UInt8, audio: Bool, continuity: UInt8) -> [UInt8] {
        var section: [UInt8] = [0x02, 0xB0, audio ? 0x17 : 0x12, 0x00, 0x01, 0xC1, 0x00, 0x00, 0xE1, 0x00, 0xF0, 0x00, video, 0xE1, 0x00, 0xF0, 0x00]
        if audio { section.append(contentsOf: [0x0F, 0xE1, 0x01, 0xF0, 0x00]) }
        return psiPacket(pid: 0x1000, section: section, continuity: continuity)
    }

    static func packets(pid: UInt16, payload: [UInt8], pcr: UInt64?, continuity: inout UInt8) -> [UInt8] {
        var output: [UInt8] = []
        var offset = 0
        var first = true
        while first || offset < payload.count {
            var packet = [UInt8](repeating: 0xFF, count: 188)
            packet[0] = 0x47
            packet[1] = ((first ? 0x40 : 0x00) | UInt8((pid >> 8) & 0x1F))
            packet[2] = UInt8(pid & 0xFF)
            let pcrNow = first ? pcr : nil
            let minimumAdaptation = pcrNow == nil ? 0 : 8
            let room = 184 - minimumAdaptation
            let remaining = payload.count - offset
            let take = min(room, remaining)
            let padding = room - take
            let adaptationTotal = minimumAdaptation + padding
            var cursor = 4
            if adaptationTotal > 0 {
                packet[3] = 0x30 | (continuity & 0x0F)
                let fieldLength = adaptationTotal - 1
                packet[4] = UInt8(fieldLength)
                cursor = 5
                if let pcrNow, fieldLength >= 7 {
                    packet[5] = 0x10
                    writePCR(pcrNow, into: &packet, at: 6)
                    cursor = 12
                } else if fieldLength > 0 {
                    packet[5] = 0x00
                    cursor = 6
                }
                cursor = 4 + adaptationTotal
            } else {
                packet[3] = 0x10 | (continuity & 0x0F)
            }
            if take > 0 {
                packet.replaceSubrange(cursor..<(cursor + take), with: payload[offset..<(offset + take)])
                offset += take
            }
            continuity = (continuity + 1) & 0x0F
            output.append(contentsOf: packet)
            first = false
            if take == 0 { break }
        }
        return output
    }

    private static func writePCR(_ base: UInt64, into packet: inout [UInt8], at index: Int) {
        let value = base & 0x1FFFFFFFF
        packet[index] = UInt8((value >> 25) & 0xFF)
        packet[index + 1] = UInt8((value >> 17) & 0xFF)
        packet[index + 2] = UInt8((value >> 9) & 0xFF)
        packet[index + 3] = UInt8((value >> 1) & 0xFF)
        packet[index + 4] = UInt8(((value & 1) << 7) | 0x7E)
        packet[index + 5] = 0
    }

    static func pes(stream: UInt8, dts: UInt64, pts: UInt64, payload: Data) -> [UInt8] {
        let both = pts != dts
        var header: [UInt8] = [0x00, 0x00, 0x01, stream, 0x00, 0x00, 0x80, both ? 0xC0 : 0x80, both ? 10 : 5]
        header.append(contentsOf: timestamp(pts, prefix: both ? 0x03 : 0x02))
        if both { header.append(contentsOf: timestamp(dts, prefix: 0x01)) }
        let afterLength = header.count - 6 + payload.count
        if afterLength <= 0xFFFF && stream != 0xE0 {
            header[4] = UInt8((afterLength >> 8) & 0xFF)
            header[5] = UInt8(afterLength & 0xFF)
        }
        var packet = header
        packet.append(contentsOf: payload)
        return packet
    }

    private static func timestamp(_ value: UInt64, prefix: UInt8) -> [UInt8] {
        let time = value & 0x1FFFFFFFF
        return [
            (prefix << 4) | UInt8((time >> 30) & 0x07) << 1 | 1,
            UInt8((time >> 22) & 0xFF),
            UInt8((time >> 15) & 0x7F) << 1 | 1,
            UInt8((time >> 7) & 0xFF),
            UInt8((time & 0x7F) << 1 | 1)
        ]
    }
}

final class FLVSegmenter {
    private var buffer = Data()
    private var headerDone = false
    private var needPreviousSize = false
    private var videoConfig: [Data] = []
    private var lengthSize = 4
    private var hevc = false
    private var audioConfig: Data?
    private(set) var sawVideo = false
    private(set) var rejectedVideo = false
    private var segments: [TSSegment] = []
    private var current = Data()
    private var started = false
    private var segmentStart: UInt32 = 0
    private var lastTime: UInt32 = 0
    private var nextIndex = 0
    private var videoCC: UInt8 = 0
    private var audioCC: UInt8 = 0
    private var patCC: UInt8 = 0
    private var pmtCC: UInt8 = 0

    var segmentCount: Int { segments.count }
    func segment(at index: Int) -> Data? { segments.first { $0.index == index }?.data }

    func append(_ data: Data) {
        buffer.append(data)
        parseAvailable()
    }

    func flush() {
        guard started else { return }
        let duration = max(0.5, Double(lastTime &- segmentStart) / 1000)
        store(duration: duration)
        started = false
    }

    func playlist() -> String {
        let target = max(1, Int((segments.map(\.duration).max() ?? 1).rounded(.up)))
        let sequence = segments.first?.index ?? 0
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:\(sequence)"]
        for segment in segments {
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append("seg/\(segment.index).ts")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func parseAvailable() {
        if !headerDone {
            guard buffer.count >= 9, buffer.starts(with: Data([0x46, 0x4C, 0x56])) else { return }
            let offset = Int(buffer[5]) << 24 | Int(buffer[6]) << 16 | Int(buffer[7]) << 8 | Int(buffer[8])
            guard buffer.count >= max(offset, 9) else { return }
            discard(offset)
            headerDone = true
            needPreviousSize = true
        }
        while true {
            if needPreviousSize {
                guard buffer.count >= 4 else { return }
                discard(4)
                needPreviousSize = false
            }
            guard buffer.count >= 11 else { return }
            let size = Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
            guard buffer.count >= 11 + size else { return }
            let time = UInt32(buffer[7]) << 24 | UInt32(buffer[4]) << 16 | UInt32(buffer[5]) << 8 | UInt32(buffer[6])
            let payload = buffer.subdata(in: 11..<(11 + size))
            consume(type: buffer[0], time: time, payload: payload)
            discard(11 + size)
            needPreviousSize = true
        }
    }

    /// `Data.removeFirst` keeps the old indices, so later `buffer[0]` traps. Copy the remainder back to a zero-based buffer.
    private func discard(_ count: Int) {
        guard count > 0 else { return }
        buffer.removeFirst(count)
        if buffer.startIndex != 0 { buffer = Data(buffer) }
    }

    private func consume(type: UInt8, time: UInt32, payload: Data) {
        if type == 9 { consumeVideo(time: time, payload: payload) }
        else if type == 8 { consumeAudio(time: time, payload: payload) }
    }

    private func consumeVideo(time: UInt32, payload: Data) {
        guard payload.count >= 5 else { return }
        let codec = payload[0] & 0x0F
        let frame = payload[0] >> 4
        guard codec == 7 || codec == 12 else {
            if frame == 1 || frame == 2 { rejectedVideo = true }
            return
        }
        let packetType = payload[1]
        let body = payload.subdata(in: 5..<payload.count)
        if packetType == 0 {
            if codec == 12 { readHEVC(body); hevc = true } else { readAVC(body); hevc = false }
            sawVideo = !videoConfig.isEmpty
            return
        }
        guard packetType == 1, frame == 1 || frame == 2, !videoConfig.isEmpty else { return }
        let composition = signed24(payload[2], payload[3], payload[4])
        push(MediaSample(timeMS: time, compositionMS: composition, keyframe: frame == 1, video: true, payload: annexB(body, keyframe: frame == 1)))
    }

    private func consumeAudio(time: UInt32, payload: Data) {
        guard payload.count >= 2, payload[0] >> 4 == 10 else { return }
        if payload[1] == 0 {
            audioConfig = payload.subdata(in: 2..<payload.count)
            return
        }
        guard payload[1] == 1, let config = audioConfig, config.count >= 2 else { return }
        var frame = Data(adts(config: config, frameLength: payload.count - 2))
        frame.append(payload.subdata(in: 2..<payload.count))
        push(MediaSample(timeMS: time, compositionMS: 0, keyframe: false, video: false, payload: frame))
    }

    private func push(_ sample: MediaSample) {
        if sample.video && sample.keyframe && started {
            let elapsed = Double(sample.timeMS &- segmentStart) / 1000
            if elapsed >= 1 {
                store(duration: max(elapsed, 0.5))
                begin(at: sample.timeMS)
            }
        } else if sample.video && sample.keyframe && !started {
            begin(at: sample.timeMS)
        }
        guard started else { return }
        write(sample)
        lastTime = sample.timeMS
    }

    private func begin(at time: UInt32) {
        current = Data(MPEGTS.pat(continuity: patCC))
        patCC = (patCC + 1) & 0x0F
        current.append(contentsOf: MPEGTS.pmt(video: hevc ? 0x24 : 0x1B, audio: audioConfig != nil, continuity: pmtCC))
        pmtCC = (pmtCC + 1) & 0x0F
        started = true
        segmentStart = time
        lastTime = time
    }

    private func write(_ sample: MediaSample) {
        let dts = UInt64(sample.timeMS) * 90
        let pts = UInt64(max(0, Int(sample.timeMS) + sample.compositionMS)) * 90
        let pes = MPEGTS.pes(stream: sample.video ? 0xE0 : 0xC0, dts: dts, pts: pts, payload: sample.payload)
        if sample.video {
            current.append(contentsOf: MPEGTS.packets(pid: 0x0100, payload: pes, pcr: dts, continuity: &videoCC))
        } else {
            current.append(contentsOf: MPEGTS.packets(pid: 0x0101, payload: pes, pcr: nil, continuity: &audioCC))
        }
    }

    private func store(duration: Double) {
        segments.append(TSSegment(index: nextIndex, duration: duration, data: current))
        nextIndex += 1
        if segments.count > 8 { segments.removeFirst() }
        current.removeAll(keepingCapacity: true)
    }

    private func readAVC(_ record: Data) {
        let bytes = [UInt8](record)
        guard bytes.count > 7 else { return }
        lengthSize = Int(bytes[4] & 0x03) + 1
        var cursor = 5
        let spsCount = Int(bytes[cursor] & 0x1F)
        cursor += 1
        var sets: [Data] = []
        for _ in 0..<spsCount {
            guard let nal = readNAL(bytes, &cursor) else { return }
            sets.append(nal)
        }
        guard cursor < bytes.count else { videoConfig = sets; return }
        let ppsCount = Int(bytes[cursor])
        cursor += 1
        for _ in 0..<ppsCount {
            guard let nal = readNAL(bytes, &cursor) else { break }
            sets.append(nal)
        }
        videoConfig = sets
    }

    private func readHEVC(_ record: Data) {
        let bytes = [UInt8](record)
        guard bytes.count > 23 else { return }
        lengthSize = Int(bytes[21] & 0x03) + 1
        let arrays = Int(bytes[22])
        var cursor = 23
        var sets: [Data] = []
        for _ in 0..<arrays {
            guard cursor + 3 <= bytes.count else { break }
            cursor += 1
            let count = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
            cursor += 2
            for _ in 0..<count {
                guard let nal = readNAL(bytes, &cursor) else { return }
                sets.append(nal)
            }
        }
        videoConfig = sets
    }

    private func readNAL(_ bytes: [UInt8], _ cursor: inout Int) -> Data? {
        guard cursor + 2 <= bytes.count else { return nil }
        let length = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
        cursor += 2
        guard length > 0, cursor + length <= bytes.count else { return nil }
        let nal = Data(bytes[cursor..<(cursor + length)])
        cursor += length
        return nal
    }

    private func annexB(_ body: Data, keyframe: Bool) -> Data {
        var output = Data([0x00, 0x00, 0x00, 0x01, 0x09, 0xF0])
        if keyframe {
            for set in videoConfig {
                output.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                output.append(set)
            }
        }
        let bytes = [UInt8](body)
        var cursor = 0
        while cursor + lengthSize <= bytes.count {
            var length = 0
            for _ in 0..<lengthSize { length = (length << 8) | Int(bytes[cursor]); cursor += 1 }
            guard length > 0, cursor + length <= bytes.count else { break }
            output.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            output.append(contentsOf: bytes[cursor..<(cursor + length)])
            cursor += length
        }
        return output
    }

    private func adts(config: Data, frameLength: Int) -> [UInt8] {
        let bytes = [UInt8](config)
        let object = (bytes[0] >> 3) & 0x1F
        let frequency = ((bytes[0] & 0x07) << 1) | (bytes[1] >> 7)
        let channel = (bytes[1] >> 3) & 0x0F
        let profile = object == 0 ? 0 : object - 1
        let full = frameLength + 7
        return [
            0xFF, 0xF1,
            (profile << 6) | (frequency << 2) | (channel >> 2),
            ((channel & 0x03) << 6) | UInt8((full >> 11) & 0x03),
            UInt8((full >> 3) & 0xFF),
            UInt8(((full & 0x07) << 5) | 0x1F),
            0xFC
        ]
    }

    private func signed24(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> Int {
        let value = (Int(a) << 16) | (Int(b) << 8) | Int(c)
        return value >= 0x800000 ? value - 0x1000000 : value
    }
}
