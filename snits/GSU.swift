//
//  GSU.swift
//  snits
//
//  Created by kevin on 2025-12-05.
//

import Foundation

final class GSU {
    // Registers
    var r = [UInt16](repeating: 0, count: 16)           // R0–R15
    var sfr: UInt16 = 0                                 // Status Flag Register
    var pbr: UInt8 = 0                                  // Program Bank Register
    var rombr: UInt8 = 0                                // ROM Bank Register
    var rambr: UInt8 = 0                                // RAM Bank Register
    var cbr: UInt16 = 0                                 // Cache Base Register
    var scbr: UInt8 = 0                                 // Screen Base Register
    var scm: UInt8 = 0                                  // Screen Mode
    var colr: UInt8 = 0                                 // Color Register
    var por: UInt8 = 0                                  // Plot Options Register
    
    // Memory
    var ram = [UInt8](repeating: 0, count: 0x10000)     // 64KB Game Pak RAM
    var cache = [UInt8](repeating: 0, count: 512)       // 512-byte instruction cache
    var cacheValid = [Bool](repeating: false, count: 512)
    
    // State
    var isRunning = false
    var go = false                                      // GO flag (starts execution)
    var irq = false                                     // IRQ request
    
    weak var bus: Bus?
    
    // Pipeline
    private var pipeline: UInt8 = 0
    private var pc: UInt16 = 0
    
    func reset() {
        r = [UInt16](repeating: 0, count: 16)
        r[15] = 0x0100  // PC starts at $01:0100
        sfr = 0x0200    // G flag set
        pbr = 0
        rombr = 0
        rambr = 0
        cbr = 0
        scbr = 0
        scm = 0
        colr = 0
        por = 0
        pipeline = 0
        pc = 0x0100
        isRunning = false
        go = false
        irq = false
        // Swift 5.x array reset
        for i in 0..<512 { cacheValid[i] = false }
    }
    
    // MARK: - Memory Access
    
    private func readROM(_ addr: UInt32) -> UInt8 {
        let bank = UInt8((addr >> 16) & 0xFF)
        let offset = addr & 0xFFFF
        
        if bank == pbr {
            let cacheOffset = Int(offset) & 0x1FF
            if cacheValid[cacheOffset] {
                return cache[cacheOffset]
            }
            // Cache miss (technically GSU fills cache lines, but simplified here)
            let romAddr = (UInt32(rombr) << 16) | UInt32(offset)
            let value = bus?.read(romAddr) ?? 0
            cache[cacheOffset] = value
            cacheValid[cacheOffset] = true
            return value
        }
        
        // Read from ROM via Bus using ROMBR
        let romAddr = (UInt32(rombr) << 16) | UInt32(offset)
        return bus?.read(romAddr) ?? 0
    }
    
    func read(_ addr: UInt32) -> UInt8 {
        if addr < 0x10000 {
            return ram[Int(addr)]
        }
        return 0xFF
    }
    
    func write(_ addr: UInt32, data: UInt8) {
        if addr < 0x10000 {
            ram[Int(addr)] = data
        }
    }
    
    // MARK: - Execution
    
    func clock(_ cycles: Int) {
        guard isRunning && go else { return }
        
        for _ in 0..<cycles {
            if pipeline == 0 {
                // Fetch
                let op = readROM((UInt32(pbr) << 16) | UInt32(pc))
                pipeline = op
                pc &+= 1
            } else {
                // Execute
                execute(pipeline)
                pipeline = 0
            }
        }
    }
    
    private func execute(_ op: UInt8) {
        let low = op & 0x0F
        
        // Handle ALT modes via SFR flags (0x100=ALT1, 0x200=ALT2, 0x300=ALT3)
        let alt1 = (sfr & 0x0100) != 0
        let alt2 = (sfr & 0x0200) != 0
        
        switch op {
        case 0x00: // STOP
            isRunning = false
            go = false
            sfr &= ~0x0020  // Clear G flag
            
        case 0x01: // NOP
            break
            
        case 0x02: // CACHE
            cbr = pc & 0xFFE0
            for i in 0..<512 { cacheValid[i] = false }
            
        case 0x03: // LSR
            let d = Int(low)
            let v = r[d]
            sfr &= ~0x0003
            if (v & 1) != 0 { sfr |= 0x0001 }  // C flag
            let res = v >> 1
            if res == 0 { sfr |= 0x0002 }      // Z flag
            r[d] = res
            
        case 0x04: // ROL
            let d = Int(low)
            let v = r[d]
            let c = (sfr & 1) << 15
            sfr &= ~0x0003
            if (v & 0x8000) != 0 { sfr |= 0x0001 }
            let res = (v << 1) | c
            if res == 0 { sfr |= 0x0002 }
            r[d] = res
            
        case 0x05...0x0F: // BRA
            let offset = Int8(bitPattern: op)
            pc = UInt16(Int(pc) + Int(offset))
            
        case 0x10...0x1F: // TO rD
            r[Int(low)] = r[0] // Move R0 to Rd
            
        case 0x20...0x2F: // WITH rD
            r[0] = r[Int(low)] // Move Rd to R0
            
        case 0x30...0x3B: // STW (rN)
            let n = Int(low & 7)
            let addr = r[n]
            write(UInt32(addr),     data: UInt8(r[0] & 0xFF))
            write(UInt32(addr + 1), data: UInt8(r[0] >> 8))
            
        case 0x3C: // LOOP
            r[12] &-= 1
            if r[12] != 0 {
                pc = r[13]
            }
            
        case 0x3D: // ALT1
            sfr |= 0x0100
            return // Don't clear flags yet
            
        case 0x3E: // ALT2
            sfr |= 0x0200
            return
            
        case 0x3F: // ALT3
            sfr |= 0x0300
            return
            
        case 0x40...0x4B: // LDW (rN)
            let n = Int(low & 7)
            let addr = r[n]
            let lo = UInt16(read(UInt32(addr)))
            let hi = UInt16(read(UInt32(addr + 1)))
            r[0] = (hi << 8) | lo
            
        case 0x4C: // PLOT / RPIX
            let x = Int(r[1])
            let y = Int(r[2])
            if (por & 0x04) != 0 { // RPIX
                // Simplified read pixel
                r[0] = 0
            } else {
                // Plot
                if x >= 0 && x < 256 && y >= 0 && y < 224 {
                    let addr = UInt32(y * 256 + x) // Simplified linear framebuffer
                    // In reality, SuperFX plots to bitplanes or RAM buffers
                    // For compilation, we just write to RAM
                    if addr < 0x10000 {
                        ram[Int(addr)] = colr
                    }
                }
            }
            r[1] &+= 1
            
        case 0x4D: // SWAP
            let v = r[0]
            r[0] = ((v & 0xFF) << 8) | (v >> 8)
            
        case 0x4E: // COLOR
            colr = UInt8(r[0] & 0xFF)
            
        case 0x4F: // NOT
            r[0] = ~r[0]
            
        case 0x50...0x5F: // ADD / ADC
            let src = alt1 ? Int(low) : Int(low)
            let val = alt1 ? UInt32(low) : UInt32(r[src]) // Immediate vs Register
            let carry = (alt1) ? UInt32(sfr & 1) : 0 // ADC only if ALT1/ALT3
            
            let sum = UInt32(r[0]) + val + carry
            sfr &= ~0x0003
            if (sum & 0x10000) != 0 { sfr |= 0x0001 }
            if (sum & 0xFFFF) == 0 { sfr |= 0x0002 }
            r[0] = UInt16(sum & 0xFFFF)
            
        case 0x60...0x6F: // SUB / SBC
            let src = Int(low)
            let a = Int32(r[0])
            let b = Int32(r[src]) // Simplified (ALT modes change this to CMP or SUB #)
            let carry = alt1 ? Int32(sfr & 1) : 0
            
            let res = a - b - carry
            sfr &= ~0x0003
            if res >= 0 { sfr |= 0x0001 }
            if Int16(truncatingIfNeeded: res) == 0 { sfr |= 0x0002 }
            r[0] = UInt16(truncatingIfNeeded: res)

        case 0x70...0x7F: // MERGE
            let high = r[7]
            let lowReg = r[8]
            r[0] = (high & 0xFF00) | ((lowReg >> 8) & 0xFF)
            r[1] = ((high << 8) & 0xFF00) | (lowReg & 0xFF)
            sfr &= ~0x0002
            if (r[0] | r[1]) != 0 { sfr |= 0x0002 } // Z flag logic approximated
            
        case 0x80...0x8F: // AND / BIC
            let src = Int(low)
            if alt1 {
                r[0] &= ~r[src] // BIC
            } else {
                r[0] &= r[src]  // AND
            }
            sfr &= ~0x0002
            if r[0] == 0 { sfr |= 0x0002 }
            
        case 0x90...0x9F: // MULT
            // Simplified 8-bit mul
            let res = Int32(Int8(r[0] & 0xFF)) * Int32(Int8(r[6] & 0xFF))
            r[0] = UInt16(bitPattern: Int16(truncatingIfNeeded: res))
            
        case 0xB0...0xBF: // FROM rN
            r[0] = r[Int(low)]
            
        case 0xE0...0xEF: // INC rN
            let d = Int(low)
            r[d] &+= 1
            sfr &= ~0x0002
            if r[d] == 0 { sfr |= 0x0002 }
            
        case 0xF0...0xFF: // DEC rN / I/O
            if op == 0xFD {
                // GETC (ROM Buffer) - Simplified
                pc &+= 1
            } else {
                let d = Int(low)
                r[d] &-= 1
                sfr &= ~0x0002
                if r[d] == 0 { sfr |= 0x0002 }
            }
            
        default:
            break
        }
        
        // Clear ALT flags after use
        sfr &= ~0x0300
    }
    
    // MARK: - External Control
    
    func start() {
        go = true
        isRunning = true
        sfr |= 0x0020  // Set G flag
    }
}
