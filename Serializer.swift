//
//  Serializer.swift
//  snes
//
//  Created by kevin on 2025-12-04.
//


import Foundation

class Serializer {
    var data = Data()
    var offset = 0
    
    init() {}
    
    init(data: Data) {
        self.data = data
    }
    
    func write8(_ val: UInt8) {
        data.append(val)
    }
    
    func write16(_ val: UInt16) {
        data.append(UInt8(val & 0xFF))
        data.append(UInt8((val >> 8) & 0xFF))
    }
    
    func write32(_ val: UInt32) {
        data.append(UInt8(val & 0xFF))
        data.append(UInt8((val >> 8) & 0xFF))
        data.append(UInt8((val >> 16) & 0xFF))
        data.append(UInt8((val >> 24) & 0xFF))
    }
    
    func writeBool(_ val: Bool) {
        data.append(val ? 1 : 0)
    }
    
    func writeBytes(_ bytes: [UInt8]) {
        data.append(contentsOf: bytes)
    }
    
    func read8() -> UInt8 {
        if offset >= data.count { return 0 }
        let val = data[offset]
        offset += 1
        return val
    }
    
    func read16() -> UInt16 {
        let lo = UInt16(read8())
        let hi = UInt16(read8())
        return (hi << 8) | lo
    }
    
    func read32() -> UInt32 {
        let b0 = UInt32(read8())
        let b1 = UInt32(read8())
        let b2 = UInt32(read8())
        let b3 = UInt32(read8())
        return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
    }
    
    func readBool() -> Bool {
        return read8() != 0
    }
    
    func readBytes(_ count: Int) -> [UInt8] {
        if offset + count > data.count { return [UInt8](repeating: 0, count: count) }
        let sub = data.subdata(in: offset..<offset+count)
        offset += count
        return [UInt8](sub)
    }
}