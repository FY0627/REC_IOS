import Foundation

/// 导出、导入用的 zip：只存不压缩（stored），文件名用 UTF-8。自己写、自己读，不用第三方库，系统「文件」App 也能直接解开。
/// 只读得懂不压缩的条目：别的软件重新压缩过的 zip 读不了，要用 REC 导出的原文件。
enum ZipStore {
    struct Entry: Hashable {
        var name: String
        var data: Data
    }

    enum ReadError: Error, Equatable {
        case notZip
        /// 条目被压缩过（不是 REC 导出的原文件）
        case compressed(String)
        case damaged(String)
    }

    // MARK: 写

    static func archive(_ entries: [Entry], modified: Date, calendar: Calendar) -> Data {
        let (time, date) = dosTime(modified, calendar: calendar)
        var output = Data()
        var directory = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let offset = UInt32(output.count)
            // 本地文件头
            output.append(le32: 0x0403_4B50)
            output.append(le16: 20)
            output.append(le16: utf8Flag)
            output.append(le16: 0)
            output.append(le16: time)
            output.append(le16: date)
            output.append(le32: crc)
            output.append(le32: UInt32(entry.data.count))
            output.append(le32: UInt32(entry.data.count))
            output.append(le16: UInt16(name.count))
            output.append(le16: 0)
            output.append(name)
            output.append(entry.data)
            // 中央目录
            directory.append(le32: 0x0201_4B50)
            directory.append(le16: 20)
            directory.append(le16: 20)
            directory.append(le16: utf8Flag)
            directory.append(le16: 0)
            directory.append(le16: time)
            directory.append(le16: date)
            directory.append(le32: crc)
            directory.append(le32: UInt32(entry.data.count))
            directory.append(le32: UInt32(entry.data.count))
            directory.append(le16: UInt16(name.count))
            directory.append(le16: 0)
            directory.append(le16: 0)
            directory.append(le16: 0)
            directory.append(le16: 0)
            directory.append(le32: 0)
            directory.append(le32: offset)
            directory.append(name)
        }
        let directoryOffset = UInt32(output.count)
        output.append(directory)
        // 中央目录结束
        output.append(le32: 0x0605_4B50)
        output.append(le16: 0)
        output.append(le16: 0)
        output.append(le16: UInt16(entries.count))
        output.append(le16: UInt16(entries.count))
        output.append(le32: UInt32(directory.count))
        output.append(le32: directoryOffset)
        output.append(le16: 0)
        return output
    }

    /// 通用标志第 11 位：文件名是 UTF-8（中文文件名在「文件」App 里不乱码）
    private static let utf8Flag: UInt16 = 0x0800

    private static func dosTime(_ date: Date, calendar: Calendar) -> (UInt16, UInt16) {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16(max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }

    // MARK: 读

    static func entries(_ data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        // 中央目录结束记录在最后（后面可能有不超过 64 KB 的注释）
        guard bytes.count >= 22 else { throw ReadError.notZip }
        var end = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        while end >= lowest, bytes.le32(end) != 0x0605_4B50 { end -= 1 }
        guard end >= lowest else { throw ReadError.notZip }
        let count = Int(bytes.le16(end + 10))
        var cursor = Int(bytes.le32(end + 16))
        var result: [Entry] = []
        for _ in 0..<count {
            guard cursor + 46 <= bytes.count, bytes.le32(cursor) == 0x0201_4B50 else { throw ReadError.damaged("中央目录") }
            let method = bytes.le16(cursor + 10)
            let crc = bytes.le32(cursor + 16)
            let size = Int(bytes.le32(cursor + 20))
            let nameLength = Int(bytes.le16(cursor + 28))
            let extraLength = Int(bytes.le16(cursor + 30))
            let commentLength = Int(bytes.le16(cursor + 32))
            let local = Int(bytes.le32(cursor + 42))
            guard cursor + 46 + nameLength <= bytes.count else { throw ReadError.damaged("文件名") }
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            cursor += 46 + nameLength + extraLength + commentLength
            // 目录条目没有内容
            if name.hasSuffix("/") { continue }
            guard method == 0 else { throw ReadError.compressed(name) }
            guard local + 30 <= bytes.count, bytes.le32(local) == 0x0403_4B50 else { throw ReadError.damaged(name) }
            let start = local + 30 + Int(bytes.le16(local + 26)) + Int(bytes.le16(local + 28))
            guard start + size <= bytes.count else { throw ReadError.damaged(name) }
            let content = Data(bytes[start..<(start + size)])
            guard crc32(content) == crc else { throw ReadError.damaged(name) }
            result.append(Entry(name: name, data: content))
        }
        return result
    }

    // MARK: CRC-32

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(le16 value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    mutating func append(le32 value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }
}

private extension Array where Element == UInt8 {
    func le16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func le32(_ offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }
}
