//
//  Cartridge.swift
//  snits
//
//  Created by kevin on 2025-12-05.
//

import Foundation

// MARK: - Enums & Structs

enum MapMode {
    case loRom
    case hiRom
    case exHiRom
}

struct SNESHeader {
    var title: String = "UNKNOWN"
    var mapMode: UInt8 = 0
    var romType: UInt8 = 0
    var romSize: UInt8 = 0
    var sramSize: UInt8 = 0
    var region: UInt8 = 0
    var company: UInt8 = 0
    var version: UInt8 = 0
    var checksumComplement: UInt16 = 0
    var checksum: UInt16 = 0
    var resetVector: UInt16 = 0
}

final class Cartridge {
    // Memory
    let romData: Data
    var sram: [UInt8]
    
    // Metadata
    var header = SNESHeader()
    var mapMode: MapMode = .loRom
    
    // Hardware Flags
    var hasBattery = false
    var hasSuperFX = false
    var hasDSP1 = false
    var hasSA1 = false
    var fastROM = false
    
    var title: String { header.title }
    
    // SRAM Calculation: 0=0, 1=2KB, 2=4KB, ... (1KB << size)
    var sramSizeBytes: Int {
        if header.sramSize == 0 { return 0 }
        // Cap at 128KB for safety, though standard max is usually 64KB (size 6)
        return min(128 * 1024, 1024 << Int(header.sramSize))
    }
    
    // MARK: - Initialization
    
    init(data: Data) {
        self.romData = data
        // Initialize 64KB SRAM buffer (default 0xFF)
        self.sram = [UInt8](repeating: 0xFF, count: 0x10000)
        
        parseHeaderAndMapMode()
        detectCoprocessors()
        
        print("Cartridge: \(title) [\(mapMode)] ROM: \(romData.count / 1024)KB SRAM: \(sramSizeBytes / 1024)KB")
    }
    
    // MARK: - Bus Interface
    
    func read(_ bank: UInt8, _ addr: UInt16) -> UInt8 {
        switch mapMode {
        case .loRom: return readLoROM(bank, addr)
        case .hiRom, .exHiRom: return readHiROM(bank, addr)
        }
    }
    
    func write(_ bank: UInt8, _ addr: UInt16, _ data: UInt8) {
        // SRAM Writing
        switch mapMode {
        case .loRom: writeLoROM(bank, addr, data)
        case .hiRom, .exHiRom: writeHiROM(bank, addr, data)
        }
    }
    
    // MARK: - LoROM Logic
    // Banks $00-$7D and $80-$FF.
    // Upper half ($8000-$FFFF) is ROM.
    // SRAM usually at $70-$7D ($0000-$7FFF) and mirrors.
    
    private func readLoROM(_ bank: UInt8, _ addr: UInt16) -> UInt8 {
        // SRAM ($70-$7D or $FE-$FF)
        if (bank >= 0x70 && bank <= 0x7D && addr < 0x8000) ||
           (bank >= 0xFE && bank <= 0xFF && addr < 0x8000) {
            if sramSizeBytes > 0 {
                let sramAddr = Int((UInt32(bank & 0xF) << 15) | UInt32(addr))
                return sram[sramAddr & (sramSizeBytes - 1)]
            }
            return 0xFF // Open Bus
        }
        
        // ROM Access
        if (addr & 0x8000) != 0 {
            // Address $8000-$FFFF map to 32KB chunks of ROM
            // PC offset = (Bank & 0x7F) * 32KB + (Addr & 0x7FFF)
            let pc = ((Int(bank) & 0x7F) << 15) | (Int(addr) & 0x7FFF)
            return readROMData(pc)
        }
        
        return 0x00 // Open Bus / System Area handled by Bus class
    }
    
    private func writeLoROM(_ bank: UInt8, _ addr: UInt16, _ data: UInt8) {
        if (bank >= 0x70 && bank <= 0x7D && addr < 0x8000) ||
           (bank >= 0xFE && bank <= 0xFF && addr < 0x8000) {
            if sramSizeBytes > 0 {
                let sramAddr = Int((UInt32(bank & 0xF) << 15) | UInt32(addr))
                sram[sramAddr & (sramSizeBytes - 1)] = data
            }
        }
    }
    
    // MARK: - HiROM Logic
    // Linear mapping. Banks $40-$7D and $C0-$FF are full 64KB ROM.
    // Banks $00-$3F and $80-$BF mirrors upper half of ROM at $8000-$FFFF.
    // SRAM usually at $20-$3F ($6000-$7FFF).
    
    private func readHiROM(_ bank: UInt8, _ addr: UInt16) -> UInt8 {
        // SRAM ($20-$3F @ $6000-$7FFF)
        if (bank >= 0x20 && bank <= 0x3F && addr >= 0x6000 && addr < 0x8000) {
            if sramSizeBytes > 0 {
                let sramAddr = Int((UInt32(bank & 0x1F) << 13) | UInt32(addr - 0x6000))
                return sram[sramAddr & (sramSizeBytes - 1)]
            }
            return 0xFF
        }
        
        // ROM Access
        // Offset = Bank * 64KB + Addr
        // But we must handle the mirroring of low banks (00-3F, 80-BF)
        
        var offset = Int(bank & 0x3F) << 16
        
        if (addr & 0x8000) == 0 {
            // $0000-$7FFF
            if (bank & 0x40) != 0 {
                // Banks 40-7D / C0-FF: Full linear access
                return readROMData(offset + Int(addr))
            }
            // Banks 00-3F / 80-BF: Low area is System/WRAM (handled by Bus)
            return 0x00
        } else {
            // $8000-$FFFF
            // Always ROM in HiROM
            return readROMData(offset + Int(addr))
        }
    }
    
    private func writeHiROM(_ bank: UInt8, _ addr: UInt16, _ data: UInt8) {
        if (bank >= 0x20 && bank <= 0x3F && addr >= 0x6000 && addr < 0x8000) {
            if sramSizeBytes > 0 {
                let sramAddr = Int((UInt32(bank & 0x1F) << 13) | UInt32(addr - 0x6000))
                sram[sramAddr & (sramSizeBytes - 1)] = data
            }
        }
    }

    // MARK: - Helpers
    
    @inline(__always)
    private func readROMData(_ index: Int) -> UInt8 {
        guard !romData.isEmpty else { return 0 }
        // Handle mirroring automatically via modulo
        // This makes 12Mbit (1.5MB) games work without complex logic
        return romData[index % romData.count]
    }
    
    // MARK: - Header Parsing
    
    private func parseHeaderAndMapMode() {
        // SNES Headers are usually at 0x7FC0 (LoROM) or 0xFFC0 (HiROM)
        // But headers can be messy. We use a scoring system.
        
        let candidates = [0x7FC0, 0xFFC0, 0x40FFC0]
        var bestScore = -1
        var bestOffset = 0
        
        for offset in candidates {
            if offset + 64 > romData.count { continue }
            let score = scoreHeader(at: offset)
            if score > bestScore {
                bestScore = score
                bestOffset = offset
            }
        }
        
        // Read header from best location
        let h = (bestScore > 0) ? bestOffset : 0x7FC0
        if h + 64 > romData.count { return } // ROM too small?
        
        header.title = romData.subdata(in: h..<(h+21)).stringASCII ?? "UNKNOWN"
        header.mapMode = romData[h+0x15]
        header.romType = romData[h+0x16]
        header.romSize = romData[h+0x17]
        header.sramSize = romData[h+0x18]
        header.region = romData[h+0x19]
        header.company = romData[h+0x1A]
        header.version = romData[h+0x1B]
        header.checksumComplement = romData.word(at: h + 0x1C)
        header.checksum = romData.word(at: h + 0x1E)
        header.resetVector = romData.word(at: h + 0x3C)
        
        // Determine Map Mode
        // $20=LoROM, $21=HiROM, $23=ExHiROM, $3x=FastROM versions
        // Simple heuristic:
        let mode = header.mapMode & 0x0F
        if mode == 0x01 || mode == 0x05 {
            mapMode = .hiRom
        } else if mode == 0x03 {
            mapMode = .exHiRom
        } else {
            mapMode = .loRom
        }
        
        hasBattery = (header.romType & 0x02) != 0
        fastROM = (header.romType & 0x10) != 0
    }
    
    private func scoreHeader(at offset: Int) -> Int {
        var score = 0
        
        // 1. Reset Vector should be in $8000-$FFFF
        let reset = romData.word(at: offset + 0x3C)
        if reset < 0x8000 { return -1 } // Unlikely
        
        // 2. Checksum + Complement = 0xFFFF
        let csum = UInt32(romData.word(at: offset + 0x1E))
        let comp = UInt32(romData.word(at: offset + 0x1C))
        if (csum + comp) == 0xFFFF { score += 10 }
        
        // 3. Valid Map Mode Byte
        let map = romData[offset + 0x15]
        if [0x20, 0x21, 0x23, 0x30, 0x31, 0x35].contains(map) { score += 2 }
        
        // 4. ROM Size Byte sanity check (0x08 = 2Mbit ... 0x0C = 32Mbit)
        let size = romData[offset + 0x17]
        if size >= 0x08 && size <= 0x0D { score += 1 }
        
        return score
    }
    
    private func detectCoprocessors() {
        let t = header.romType
        // $00=ROM, $01=RAM, $02=RAM+BAT, $03=DSP, $04=DSP+RAM, $05=DSP+RAM+BAT
        // $1x=SuperFX, $3x=SA-1, etc.
        
        hasDSP1 = (t == 0x03 || t == 0x04 || t == 0x05)
        hasSuperFX = (t >= 0x13 && t <= 0x1A)
        hasSA1 = (t == 0x34 || t == 0x35)
    }
    
    // MARK: - Persistence
    
    func saveSRAM(to url: URL) {
        guard hasBattery, sramSizeBytes > 0 else { return }
        let data = Data(sram.prefix(sramSizeBytes))
        try? data.write(to: url)
    }
    
    func loadSRAM(from url: URL) {
        guard hasBattery, sramSizeBytes > 0 else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        
        let count = min(data.count, sram.count)
        data.copyBytes(to: &sram, from: 0..<count)
        print("SRAM Loaded: \(count) bytes")
    }
}

// MARK: - Data Extensions

extension Data {
    var stringASCII: String? {
        String(data: self, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func word(at offset: Int) -> UInt16 {
        guard count > offset + 1 else { return 0 }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }
}
