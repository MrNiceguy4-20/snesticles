//
//  Serializer.swift
//  snits
//
//  Created by kevin on 2025-12-05.
//

import Foundation

/// A high-performance, endian-safe binary serializer for Save States.
final class Serializer {
    private var buffer: Data
    private var readOffset: Int = 0
    
    // MARK: - Initialization
    
    /// Initialize for WRITING (New Save State)
    init() {
        self.buffer = Data()
        self.readOffset = 0
    }
    
    /// Initialize for READING (Load Save State)
    init(data: Data) {
        self.buffer = data
        self.readOffset = 0
    }
    
    // MARK: - Writing (Append)
    
    func write(_ value: Bool) {
        buffer.append(value ? 1 : 0)
    }
    
    func write(_ value: UInt8) {
        buffer.append(value)
    }
    
    func write(_ value: Int8) {
        buffer.append(UInt8(bitPattern: value))
    }
    
    func write(_ value: UInt16) {
        buffer.append(UInt8(value & 0xFF))
        buffer.append(UInt8((value >> 8) & 0xFF))
    }
    
    func write(_ value: Int16) {
        write(UInt16(bitPattern: value))
    }
    
    func write(_ value: UInt32) {
        buffer.append(UInt8(value & 0xFF))
        buffer.append(UInt8((value >> 8) & 0xFF))
        buffer.append(UInt8((value >> 16) & 0xFF))
        buffer.append(UInt8((value >> 24) & 0xFF))
    }
    
    func write(_ value: Int32) {
        write(UInt32(bitPattern: value))
    }
    
    // Array Helpers
    func write(_ array: [UInt8]) {
        buffer.append(contentsOf: array)
    }
    
    func write(_ array: [UInt16]) {
        for v in array { write(v) }
    }
    
    func write(_ array: [UInt32]) {
        for v in array { write(v) }
    }
    
    // MARK: - Reading
    
    func readBool() -> Bool {
        return readUInt8() != 0
    }
    
    func readUInt8() -> UInt8 {
        guard readOffset < buffer.count else { return 0 }
        let val = buffer[readOffset]
        readOffset += 1
        return val
    }
    
    func readInt8() -> Int8 {
        return Int8(bitPattern: readUInt8())
    }
    
    func readUInt16() -> UInt16 {
        guard readOffset + 2 <= buffer.count else { return 0 }
        let lo = UInt16(buffer[readOffset])
        let hi = UInt16(buffer[readOffset + 1])
        readOffset += 2
        return (hi << 8) | lo
    }
    
    func readInt16() -> Int16 {
        return Int16(bitPattern: readUInt16())
    }
    
    func readUInt32() -> UInt32 {
        guard readOffset + 4 <= buffer.count else { return 0 }
        let b0 = UInt32(buffer[readOffset])
        let b1 = UInt32(buffer[readOffset + 1])
        let b2 = UInt32(buffer[readOffset + 2])
        let b3 = UInt32(buffer[readOffset + 3])
        readOffset += 4
        return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
    }
    
    func readInt32() -> Int32 {
        return Int32(bitPattern: readUInt32())
    }
    
    // Array Helpers
    func readBytes(count: Int) -> [UInt8] {
        guard readOffset + count <= buffer.count else {
            // Safety: If file is truncated, return zeros instead of crashing
            readOffset = buffer.count
            return [UInt8](repeating: 0, count: count)
        }
        let sub = buffer[readOffset..<readOffset+count]
        readOffset += count
        return Array(sub)
    }
    
    // MARK: - Access
    
    /// Retrieve the serialized blob (for saving to disk)
    var data: Data {
        return buffer
    }
}
