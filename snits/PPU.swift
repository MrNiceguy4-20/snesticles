import Foundation

final class PPU {
    unowned let renderer: MetalRenderer
    
    // Memory
    var vram = [UInt8](repeating: 0, count: 0x10000)
    var cgram = [UInt16](repeating: 0, count: 256)
    var oam = [UInt8](repeating: 0, count: 544)
    
    // Registers
    var currentScanline: Int = 0
    var inVBlank = false
    var nmiFlag = false
    var irqFlag = false
    var nmiEnabled = false
    var irqEnabled = false
    var forceBlank = true
    var brightness: UInt8 = 0
    
    // BG
    var bgMode: UInt8 = 0
    var mosaicEnabled: UInt8 = 0
    var mosaicSize: UInt8 = 1
    var bgSC = [UInt8](repeating: 0, count: 4)
    var bgNBA = [UInt8](repeating: 0, count: 4)
    var bgHOffset = [UInt16](repeating: 0, count: 4)
    var bgVOffset = [UInt16](repeating: 0, count: 4)
    
    // Mode 7 / Math
    var tm: UInt8 = 0x0F
    var cgwsel: UInt8 = 0
    var fixedColor: UInt8 = 0
    
    // VRAM
    var vramAddr: UInt16 = 0
    var vramIncrement: UInt8 = 1
    
    // Internal
    private var cgramAddress: UInt8 = 0
    private var cgramWriteLow: Bool = false
    private(set) var framebuffer = [UInt32](repeating: 0, count: 256 * 224)
    
    init(renderer: MetalRenderer) { self.renderer = renderer }
    
    func reset() {
        vram = [UInt8](repeating: 0, count: 0x10000)
        cgram = [UInt16](repeating: 0, count: 256)
        oam = [UInt8](repeating: 0, count: 544)
        framebuffer = [UInt32](repeating: 0, count: 256 * 224)
        currentScanline = 0
        inVBlank = false
    }
    
    func read(_ addr: UInt16) -> UInt8 { return 0 }
    
    func write(_ addr: UInt16, _ value: UInt8) {
        switch addr {
        case 0x2100:
            forceBlank = value & 0x80 != 0
            brightness = value & 0x0F
        case 0x2105:
            bgMode = value & 0x07
            mosaicEnabled = value & 0x08
        case 0x2106:
            mosaicSize = (value >> 4) + 1
        case 0x2107...0x210A:
            bgSC[Int(addr - 0x2107)] = value
        case 0x210B...0x210C:
            let idx = Int(addr - 0x210B) * 2
            bgNBA[idx] = value & 0x0F
            bgNBA[idx + 1] = value >> 4
        case 0x210D...0x2114:
            let bg = Int((addr - 0x210D) / 2)
            if (addr & 1) == 1 {
                bgHOffset[bg] = (bgHOffset[bg] & 0xFF00) | (UInt16(value) << 8) | (bgHOffset[bg] & 0x00FF)
            } else {
                bgHOffset[bg] = (bgHOffset[bg] & 0xFF00) | UInt16(value)
            }
        case 0x2115:
            vramIncrement = (value & 0x80 != 0) ? 32 : 1
        case 0x2116: vramAddr = (vramAddr & 0xFF00) | UInt16(value)
        case 0x2117: vramAddr = (UInt16(value) << 8) | (vramAddr & 0x00FF)
        case 0x2118:
            vram[Int(vramAddr) * 2] = value
        case 0x2119:
            vram[Int(vramAddr) * 2 + 1] = value
            vramAddr &+= UInt16(vramIncrement)
        case 0x2121:
            cgramAddress = value
            cgramWriteLow = false
        case 0x2122:
            if !cgramWriteLow {
                cgram[Int(cgramAddress)] = (cgram[Int(cgramAddress)] & 0xFF00) | UInt16(value)
                cgramWriteLow = true
            } else {
                cgram[Int(cgramAddress)] = (cgram[Int(cgramAddress)] & 0x00FF) | (UInt16(value & 0x1F) << 5)
                cgramWriteLow = false
                cgramAddress &+= 1
            }
        case 0x212C: tm = value
        default: break
        }
    }
    
    // Save/Load
    func save(to s: Serializer) { s.write(vram); s.write(oam) }
    func load(from s: Serializer) { vram = s.readBytes(count: 0x10000); oam = s.readBytes(count: 544) }
    
    // Rendering
    func endFrame() {
        if currentScanline < 224 { renderScanline(currentScanline) }
        currentScanline += 1
        if currentScanline == 225 {
            inVBlank = true
            if nmiEnabled { nmiFlag = true }
        } else if currentScanline == 262 {
            inVBlank = false
            nmiFlag = false
            currentScanline = 0
        }
        renderer.updateTexture(with: &framebuffer)
    }
    
    private func renderScanline(_ line: Int) {
        // Simplified Rendering for compilation safety
        guard !forceBlank else {
            let black = UInt32(brightness) * 0x010101
            for i in 0..<256 { framebuffer[line * 256 + i] = black }
            return
        }
        
        var lineBuffer = [UInt16](repeating: 0, count: 256)
        
        // Simple BG1 Render
        if (tm & 0x01) != 0 {
            let sc = bgSC[0]
            let tilemapBase = Int(sc & 0xFC) << 9
            let hScroll = Int(bgHOffset[0])
            let vScroll = Int(bgVOffset[0])
            
            for x in 0..<256 {
                let tileX = (hScroll + x) >> 3
                let tileY = (vScroll + line) >> 3
                let mapAddr = tilemapBase + ((tileY & 31) * 32 + (tileX & 31))
                let tileNum = Int(vram[mapAddr * 2]) // Simple low byte only
                // Logic simplified...
                if tileNum > 0 { lineBuffer[x] = cgram[1] } // Test color
            }
        }
        
        // Output
        for x in 0..<256 {
            let c = lineBuffer[x]
            let r = UInt32((c & 0x1F) << 3)
            let g = UInt32(((c >> 5) & 0x1F) << 3)
            let b = UInt32(((c >> 10) & 0x1F) << 3)
            framebuffer[line * 256 + x] = 0xFF000000 | (r << 16) | (g << 8) | b
        }
    }
    
    func drawTestPattern(_ type: TestPattern) {
        renderer.updateTexture(with: &framebuffer)
    }
}
