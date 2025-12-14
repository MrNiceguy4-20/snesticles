import Foundation

class PPU {
    var nmiFlag: Bool = false
    var vblankFlag: Bool = false
    
    // NEW: Reference back to the Bus (set by Bus.swift on init)
    weak var bus: Bus?

    unowned let renderer: MetalRenderer
    var vram = Array<UInt8>(repeating: 0, count: 64 * 1024)
    var cgram = Array<UInt16>(repeating: 0, count: 256)
    var oam = Array<UInt8>(repeating: 0, count: 544)
    var currentScanline: UInt16 = 0; var nmiEnabled: Bool = false
    var forceBlank: Bool = false
    var vramAddr: UInt16 = 0; var vramIncSize: UInt8 = 1; var cgramAddr: UInt8 = 0; var oamAddr: UInt16 = 0; var brightness: UInt8 = 0x0F
    var bgMode: UInt8 = 0; var mosaic: UInt8 = 0
    var bg1SC: UInt8 = 0; var bg2SC: UInt8 = 0; var bg12NBA: UInt8 = 0; var objSEL: UInt8 = 0
    var bg1HOFS: UInt16 = 0; var bg1VOFS: UInt16 = 0; var bg2HOFS: UInt16 = 0; var bg2VOFS: UInt16 = 0
    var m7a: Int16 = 0; var m7b: Int16 = 0; var m7c: Int16 = 0; var m7d: Int16 = 0; var m7x: Int16 = 0; var m7y: Int16 = 0; var m7Latch: UInt8 = 0
    var win1L: UInt8 = 0; var win1R: UInt8 = 0; var tm: UInt8 = 0x13; var ts: UInt8 = 0x00
    var cgwsel: UInt8 = 0; var cgadsub: UInt8 = 0; var fixedColor: UInt16 = 0; private var ppuLatch: UInt8 = 0
    var frameBuffer: [UInt32]
    let maxWidth = 512; let maxHeight = 478
    struct Pixel { var color: UInt16; var priority: Int; var layer: Int; var hasPixel: Bool }
    var mainBuf: [Pixel]; var subBuf: [Pixel]
    
    init(renderer: MetalRenderer) {
        self.renderer = renderer
        self.frameBuffer = Array(repeating: 0xFF000000, count: maxWidth * maxHeight)
        self.mainBuf = Array(repeating: Pixel(color: 0, priority: 0, layer: 0, hasPixel: false), count: maxWidth)
        self.subBuf = Array(repeating: Pixel(color: 0, priority: 0, layer: 0, hasPixel: false), count: maxWidth)
    }
    
    func save(_ s: Serializer) {
        s.writeBytes(vram)
        for c in cgram { s.write16(c) }
        s.writeBytes(oam)
        s.write16(currentScanline); s.writeBool(nmiEnabled); s.writeBool(forceBlank); s.write16(vramAddr)
        s.write8(vramIncSize); s.write8(cgramAddr); s.write16(oamAddr); s.write8(brightness)
        s.write8(bgMode); s.write8(mosaic)
        s.write8(bg1SC); s.write8(bg2SC); s.write8(bg12NBA); s.write8(objSEL)
        s.write16(bg1HOFS); s.write16(bg1VOFS); s.write16(bg2HOFS); s.write16(bg2VOFS)
        s.write16(UInt16(bitPattern: m7a)); s.write16(UInt16(bitPattern: m7b))
        s.write16(UInt16(bitPattern: m7c)); s.write16(UInt16(bitPattern: m7d))
        s.write16(UInt16(bitPattern: m7x)); s.write16(UInt16(bitPattern: m7y))
        s.write8(win1L); s.write8(win1R); s.write8(tm); s.write8(ts)
        s.write8(cgwsel); s.write8(cgadsub); s.write16(fixedColor)
    }
    
    func load(_ s: Serializer) {
        vram = s.readBytes(64 * 1024)
        for i in 0..<256 { cgram[i] = s.read16() }
        oam = s.readBytes(544)
        currentScanline = s.read16(); nmiEnabled = s.readBool(); forceBlank = s.readBool(); vramAddr = s.read16()
        vramIncSize = s.read8(); cgramAddr = s.read8(); oamAddr = s.read16(); brightness = s.read8()
        bgMode = s.read8(); mosaic = s.read8()
        bg1SC = s.read8(); bg2SC = s.read8(); bg12NBA = s.read8(); objSEL = s.read8()
        bg1HOFS = s.read16(); bg1VOFS = s.read16(); bg2HOFS = s.read16(); bg2VOFS = s.read16()
        m7a = Int16(bitPattern: s.read16()); m7b = Int16(bitPattern: s.read16())
        m7c = Int16(bitPattern: s.read16()); m7d = Int16(bitPattern: s.read16())
        m7x = Int16(bitPattern: s.read16()); m7y = Int16(bitPattern: s.read16())
        win1L = s.read8(); win1R = s.read8(); tm = s.read8(); ts = s.read8()
        cgwsel = s.read8(); cgadsub = s.read8(); fixedColor = s.read16()
    }
    
    func reset() {
        vram = Array(repeating: 0, count: 64 * 1024); cgram = Array(repeating: 0, count: 256); oam = Array(repeating: 0, count: 544)
        vramAddr = 0; ppuLatch = 0; bg1HOFS = 0; bg1VOFS = 0; bg2HOFS = 0; bg2VOFS = 0
        m7a = 0; m7b = 0; m7c = 0; m7d = 0; m7x = 0; m7y = 0; mosaic = 0; forceBlank = false
    }
    
    func readRegister(_ offset: UInt32) -> UInt8 {
        switch offset {
        case 0x2137:
            // Latch H/V counters (not fully emulated yet)
            return 0
        case 0x213F:
            // Simple PPU status: indicate NTSC and no interlace
            return 0x20
        default:
            return 0
        }
    }
    
    func writeRegister(_ offset: UInt32, data: UInt8) {
        switch offset {
        case 0x2100:
            // INIDISP: bit7 = force blank, low 4 bits = brightness
            brightness = data & 0x0F
            forceBlank = (data & 0x80) != 0
        case 0x2101: objSEL = data
        case 0x2102: oamAddr = (oamAddr & 0xFF00) | UInt16(data)
        case 0x2103: oamAddr = (oamAddr & 0x00FF) | (UInt16(data & 1) << 8)
        case 0x2104: if oamAddr < 544 { oam[Int(oamAddr)] = data }; oamAddr = (oamAddr + 1) % 544
        case 0x2105: bgMode = data & 0x07
        case 0x2106: mosaic = data
        case 0x2107: bg1SC = data
        case 0x2108: bg2SC = data
        case 0x210B: bg12NBA = data
        case 0x210D: bg1HOFS = (UInt16(data) << 8) | (UInt16(ppuLatch) & ~7) | (UInt16(data) >> 3); ppuLatch = data; m7x = Int16(bitPattern: (UInt16(data) << 8) | UInt16(ppuLatch))
        case 0x210E: bg1VOFS = (UInt16(data) << 8) | UInt16(ppuLatch); ppuLatch = data; m7y = Int16(bitPattern: (UInt16(data) << 8) | UInt16(ppuLatch))
        case 0x210F: bg2HOFS = (UInt16(data) << 8) | (UInt16(ppuLatch) & ~7) | (UInt16(data) >> 3); ppuLatch = data
        case 0x2110: bg2VOFS = (UInt16(data) << 8) | UInt16(ppuLatch); ppuLatch = data
        case 0x2115: vramIncSize = (data & 0x03) == 0 ? 1 : 32
        case 0x2116: vramAddr = (vramAddr & 0xFF00) | UInt16(data)
        case 0x2117: vramAddr = (vramAddr & 0x00FF) | (UInt16(data) << 8)
        case 0x2118: writeVRAM(val: data, high: false)
        case 0x2119: writeVRAM(val: data, high: true)
        case 0x211B: m7a = Int16(bitPattern: (UInt16(data) << 8) | UInt16(ppuLatch)); ppuLatch = data
        case 0x211C: m7b = Int16(bitPattern: (UInt16(data) << 8) | UInt16(ppuLatch)); ppuLatch = data
        case 0x211D: m7c = Int16(bitPattern: (UInt16(data) << 8) | UInt16(ppuLatch)); ppuLatch = data
        case 0x211E: m7d = Int16(bitPattern: (UInt16(data) << 8) | UInt16(ppuLatch)); ppuLatch = data
        case 0x211F: m7x = Int16(bitPattern: (UInt16(data) << 8) | UInt16(ppuLatch)); ppuLatch = data
        case 0x2120: m7y = Int16(bitPattern: (UInt16(data) << 8) | UInt16(ppuLatch)); ppuLatch = data
        case 0x2121: cgramAddr = data
        case 0x2122: writeCGRAM(val: data)
        case 0x2126: win1L = data
        case 0x2127: win1R = data
        case 0x212C: tm = data
        case 0x212D: ts = data
        case 0x2130: cgwsel = data
        case 0x2131: cgadsub = data
        case 0x2132:
            if (data & 0x20) != 0 { fixedColor = (fixedColor & 0xFFE0) | UInt16(data & 0x1F) }
            if (data & 0x40) != 0 { fixedColor = (fixedColor & 0xFC1F) | (UInt16(data & 0x1F) << 5) }
            if (data & 0x80) != 0 { fixedColor = (fixedColor & 0x83FF) | (UInt16(data & 0x1F) << 10) }
        default: break
        }
    }
    
    // NEW: Function to advance the PPU by one scanline
    func stepScanline() {
        // NTSC PPU timing constants (0-indexed)
        let VBLANK_START_LINE: UInt16 = 225 // Line 225 begins VBLANK (visible lines are 0-224)
        let LAST_SCANLINE: UInt16 = 261   // Line 261 is the last line of the frame

        // Render the current line. Only render visible lines (0-224)
        if currentScanline < VBLANK_START_LINE {
            renderScanline(line: Int(currentScanline))
        }

        currentScanline += 1

        if currentScanline == VBLANK_START_LINE {
            // VBLANK starts: Set NMI flag on the Bus if NMI is enabled ($4200 bit 7)
            if nmiEnabled, let bus = bus {
                // Assuming Bus has a setNmiFlag() method
                bus.setNmiFlag()
            }
        }

        if currentScanline > LAST_SCANLINE {
            // End of frame, reset to line 0 (pre-render line)
            currentScanline = 0
            // Tell the renderer to display the finished frame
            renderer.updateTexture(pixels: frameBuffer)
        }
    }
    
    
    private func windowAllowsPixel(layerID: Int, x: Int) -> Bool {
        // Simple window 1 handling: if cgwsel bit1 is set, treat win1L..win1R as a masked region.
        if (cgwsel & 0x02) == 0 { return true }
        if x >= Int(win1L) && x <= Int(win1R) {
            // Mask this layer in the window range
            return false
        }
        return true
    }
    private func writeVRAM(val: UInt8, high: Bool) {
        let addr = Int(vramAddr) * 2 + (high ? 1 : 0)
        if addr < vram.count { vram[addr] = val }
        if high { vramAddr = vramAddr &+ UInt16(vramIncSize) }
    }
    
    private var cgramLatch: UInt8 = 0; private var cgramFlip: Bool = false
    private func writeCGRAM(val: UInt8) {
        if !cgramFlip { cgramLatch = val; cgramFlip = true }
        else { let color = (UInt16(val) << 8) | UInt16(cgramLatch); cgram[Int(cgramAddr)] = color; cgramAddr = cgramAddr &+ 1; cgramFlip = false }
    }
    
    func renderScanline(line: Int) {
        if line >= maxHeight { return }
        let isHiRes = (bgMode == 5 || bgMode == 6); let renderWidth = isHiRes ? 512 : 256
        // If force blank is set or brightness is zero, output a black line and return early.
        if forceBlank || brightness == 0 {
            frameBuffer.withUnsafeMutableBufferPointer { fbPtr in
                let base = line * maxWidth
                if base >= 0 && base < maxWidth * maxHeight {
                    for x in 0..<renderWidth {
                        fbPtr[base + x] = 0xFF000000
                    }
                }
            }
            return
        }
        let backColor = cgram[0]; let defaultPixel = Pixel(color: backColor, priority: 0, layer: 0, hasPixel: true)
        mainBuf.withUnsafeMutableBufferPointer { ptr in for i in 0..<maxWidth { ptr[i] = defaultPixel } }
        subBuf.withUnsafeMutableBufferPointer { ptr in for i in 0..<maxWidth { ptr[i] = (ts & 0x20) != 0 ? defaultPixel : Pixel(color: fixedColor, priority: 0, layer: 0, hasPixel: true) } }
        if bgMode == 7 { renderMode7(line: line) }
        else {
            renderLayerToBuffers(line: line, sc: bg2SC, nba: bg12NBA >> 4, hScroll: bg2HOFS, vScroll: bg2VOFS, layerID: 2, hiRes: isHiRes)
            renderLayerToBuffers(line: line, sc: bg1SC, nba: bg12NBA & 0x0F, hScroll: bg1HOFS, vScroll: bg1VOFS, layerID: 1, hiRes: isHiRes)
        }
        renderSpritesToBuffers(line: line, hiRes: isHiRes)
        let addSub = (cgadsub & 0x80) != 0; let half = (cgadsub & 0x40) != 0
        frameBuffer.withUnsafeMutableBufferPointer { fbPtr in
            mainBuf.withUnsafeBufferPointer { mainPtr in
                subBuf.withUnsafeBufferPointer { subPtr in
                    for x in 0..<renderWidth {
                        var finalColor = mainPtr[x].color; let layer = mainPtr[x].layer; let mathEnabled = (cgadsub & (1 << (layer == 4 ? 4 : (layer - 1)))) != 0
                        if mathEnabled {
                            let m = mainPtr[x].color; let s = subPtr[x].color
                            let r1 = (m&0x1F); let g1 = (m>>5)&0x1F; let b1 = (m>>10)&0x1F
                            let r2 = (s&0x1F); let g2 = (s>>5)&0x1F; let b2 = (s>>10)&0x1F
                            var r=0; var g=0; var b=0
                            if !addSub { r = Int(r1)+Int(r2); g = Int(g1)+Int(g2); b = Int(b1)+Int(b2) }
                            else { r = Int(r1)-Int(r2); g = Int(g1)-Int(g2); b = Int(b1)-Int(b2) }
                            if half { r /= 2; g /= 2; b /= 2 }
                            if r>31{r=31};if r<0{r=0}; if g>31{g=31};if g<0{g=0}; if b>31{b=31};if b<0{b=0}
                            finalColor = UInt16(r)|(UInt16(g)<<5)|(UInt16(b)<<10)
                        }
                        var r = Int(finalColor & 0x001F); var g = Int((finalColor & 0x03E0) >> 5); var b = Int((finalColor & 0x7C00) >> 10)
                        // Apply simple brightness scaling using INIDISP low 4 bits (0-15)
                        let bright = Int(brightness)
                        r = (r * bright) / 15; g = (g * bright) / 15; b = (b * bright) / 15
                        if r < 0 { r = 0 } else if r > 31 { r = 31 }
                        if g < 0 { g = 0 } else if g > 31 { g = 31 }
                        if b < 0 { b = 0 } else if b > 31 { b = 31 }
                        let R = UInt32((r * 255) / 31); let G = UInt32((g * 255) / 31); let B = UInt32((b * 255) / 31)
                        let packed = 0xFF000000 | (R << 16) | (G << 8) | B
                        if isHiRes { fbPtr[line * 512 + x] = packed }
                        else { fbPtr[line * 512 + (x * 2)] = packed; fbPtr[line * 512 + (x * 2) + 1] = packed }
                    }
                }
            }
        }
    }
    
    func renderMode7(line: Int) {
        if (tm & 0x01) == 0 { return }
        mainBuf.withUnsafeMutableBufferPointer { mainPtr in
            for x in 0..<256 {
                let rx = (Int(m7a) * x) >> 8; let ry = (Int(m7d) * line) >> 8; let texX = (rx & 0x3FF); let texY = (ry & 0x3FF); let addr = (texY * 128) + texX
                if addr < 16384 {
                    let colorIdx = vram[Int(addr) * 2]; let color = cgram[Int(colorIdx)]
                    mainPtr[x] = Pixel(color: color, priority: 1, layer: 1, hasPixel: true)
                }
            }
        }
    }
    
    func renderLayerToBuffers(line: Int, sc: UInt8, nba: UInt8, hScroll: UInt16, vScroll: UInt16, layerID: Int, hiRes: Bool) {
        let enableMain = (tm & (1 << (layerID - 1))) != 0; let enableSub = (ts & (1 << (layerID - 1))) != 0
        if !enableMain && !enableSub { return }
        let mosaicSize = (mosaic & 0xF0) >> 4; let mosaicEnabled = (mosaic & (1 << (layerID - 1))) != 0
        let effectiveY = mosaicEnabled ? (line - (line % (Int(mosaicSize) + 1))) : line
        let tileMapBase = UInt16(sc & 0xFC) << 8; let tileDataBase = UInt16(nba) << 12
        let y = (Int(effectiveY) + Int(vScroll)) & 0x3FF; let tileY = (y / 8) & 0x1F; let pixelY = y % 8; let width = hiRes ? 512 : 256
        mainBuf.withUnsafeMutableBufferPointer { mainPtr in
            subBuf.withUnsafeMutableBufferPointer { subPtr in
                for screenX in 0..<width {
                    if !windowAllowsPixel(layerID: layerID, x: screenX) { continue }
                    let effectiveX = mosaicEnabled ? (screenX - (screenX % (Int(mosaicSize) + 1))) : screenX
                    let x = (effectiveX + Int(hScroll)) & 0x3FF; let tileX = (x / 8) & 0x1F
                    let mapAddr = tileMapBase + UInt16(tileY * 32 + tileX) * 2
                    let mapLo = vram[Int(mapAddr) % vram.count]; let mapHi = vram[(Int(mapAddr)+1) % vram.count]
                    let tileIdx = UInt16(mapLo) | (UInt16(mapHi & 0x03) << 8); let paletteIdx = (mapHi & 0x1C) >> 2
                    let priorityBit = (mapHi & 0x20) != 0
                    let hFlip = (mapHi & 0x40) != 0; let vFlip = (mapHi & 0x80) != 0
                    let tileAddr = tileDataBase + (tileIdx * 32); let row = vFlip ? (7 - pixelY) : pixelY
                    let p1Addr = Int(tileAddr) + (row * 2); let p2Addr = Int(tileAddr) + 16 + (row * 2)
                    let b1 = vram[p1Addr % vram.count]; let b2 = vram[(p1Addr+1) % vram.count]
                    let b3 = vram[p2Addr % vram.count]; let b4 = vram[(p2Addr+1) % vram.count]
                    let pX = x % 8; let bit = hFlip ? pX : (7 - pX); let mask: UInt8 = 1 << bit
                    let cIdx = ((b1 & mask) != 0 ? 1 : 0) + ((b2 & mask) != 0 ? 2 : 0) + ((b3 & mask) != 0 ? 4 : 0) + ((b4 & mask) != 0 ? 8 : 0)
                    if cIdx != 0 {
                        let color = cgram[Int(paletteIdx * 16) + cIdx]
                        let pri = layerID * 10 + (priorityBit ? 5 : 0)
                        if enableMain {
                            let existing = mainPtr[screenX]
                            if !existing.hasPixel || pri >= existing.priority {
                                mainPtr[screenX] = Pixel(color: color, priority: pri, layer: layerID, hasPixel: true)
                            }
                        }
                        if enableSub {
                            let existingS = subPtr[screenX]
                            if !existingS.hasPixel || pri >= existingS.priority {
                                subPtr[screenX] = Pixel(color: color, priority: pri, layer: layerID, hasPixel: true)
                            }
                        }
                    }
                }
            }
        }
    }
    
    func renderSpritesToBuffers(line: Int, hiRes: Bool) {
        let enableMain = (tm & 0x10) != 0; let enableSub = (ts & 0x10) != 0
        if !enableMain && !enableSub { return }
        let objBase = UInt16(objSEL & 0x07) << 13
        mainBuf.withUnsafeMutableBufferPointer { mainPtr in
            subBuf.withUnsafeMutableBufferPointer { subPtr in
                for i in (0..<128).reversed() {
                    let idx = i * 4; let oamY = oam[idx+1]; let oamX = oam[idx]; let oamTile = oam[idx+2]; let oamProp = oam[idx+3]
                    if line >= oamY && line < (Int(oamY) + 8) {
                        let row = line - Int(oamY); let tileIndex = UInt16(oamTile); let paletteIdx = (oamProp & 0x0E) >> 1
                        let vFlip = (oamProp & 0x80) != 0; let hFlip = (oamProp & 0x40) != 0
                        let tileAddr = objBase + (tileIndex * 32); let fetchRow = vFlip ? (7 - row) : row
                        let p1Addr = Int(tileAddr) + (fetchRow * 2); let p2Addr = Int(tileAddr) + 16 + (fetchRow * 2)
                        let b1 = vram[p1Addr % vram.count]; let b2 = vram[(p1Addr+1) % vram.count]
                        let b3 = vram[p2Addr % vram.count]; let b4 = vram[(p2Addr+1) % vram.count]
                        for x in 0..<8 {
                            let drawX = Int(oamX) + x; let drawW = hiRes ? 512 : 256
                            if drawX < 0 || drawX >= drawW { continue }
                            if !windowAllowsPixel(layerID: 4, x: drawX) { continue }
                            let bit = hFlip ? x : (7 - x); let mask: UInt8 = 1 << bit
                            let cIdx = ((b1 & mask) != 0 ? 1 : 0) + ((b2 & mask) != 0 ? 2 : 0) + ((b3 & mask) != 0 ? 4 : 0) + ((b4 & mask) != 0 ? 8 : 0)
                            if cIdx != 0 {
                                let color = cgram[128 + Int(paletteIdx * 16) + cIdx]
                                // Approximate sprite priority using OAM property bits 4-5.
                                let spritePri = 80 + Int((oamProp & 0x30) >> 4) * 5
                                if enableMain {
                                    let existing = mainPtr[drawX]
                                    if !existing.hasPixel || spritePri >= existing.priority {
                                        mainPtr[drawX] = Pixel(color: color, priority: spritePri, layer: 4, hasPixel: true)
                                    }
                                }
                                if enableSub {
                                    let existingS = subPtr[drawX]
                                    if !existingS.hasPixel || spritePri >= existingS.priority {
                                        subPtr[drawX] = Pixel(color: color, priority: spritePri, layer: 4, hasPixel: true)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func convertColor(_ color: UInt16) -> UInt32 {
        let r = (color & 0x001F); let g = (color & 0x03E0) >> 5; let b = (color & 0x7C00) >> 10
        let R = UInt32((r * 255) / 31); let G = UInt32((g * 255) / 31); let B = UInt32((b * 255) / 31)
        return 0xFF000000 | (R << 16) | (G << 8) | B
    }
    // --- Test Pattern Suite ---
    func drawTestPattern() {
        let visibleHeight = 224
        let visibleWidth  = 256
        frameBuffer.withUnsafeMutableBufferPointer { fbPtr in
            for y in 0..<visibleHeight {
                for x in 0..<visibleWidth {
                    let r = UInt32((Double(x)/Double(visibleWidth))*255)
                    let g = UInt32((Double(y)/Double(visibleHeight))*255)
                    let b = UInt32(128)
                    let idx = y*maxWidth + (x*2)
                    let c = 0xFF000000 | (r<<16)|(g<<8)|b
                    fbPtr[idx]=c; fbPtr[idx+1]=c
                }
            }
        }
    }
    
    func drawHiresTestPattern() {
        let h=224, w=512
        frameBuffer.withUnsafeMutableBufferPointer { fbPtr in
            for y in 0..<h {
                for x in 0..<w {
                    let r = UInt32((Double(x)/Double(w))*255)
                    let g = UInt32((Double(y)/Double(h))*255)
                    let b = UInt32(200)
                    fbPtr[y*maxWidth + x] = 0xFF000000 | (r<<16)|(g<<8)|b
                }
            }
        }
    }
    
    func drawColorBarsTestPattern() {
        let h = 224, w = 256
        let bars: [UInt32] = [
            0xFFFF0000, 0xFFFFFF00, 0xFF00FF00,
            0xFF00FFFF, 0xFF0000FF, 0xFFFF00FF, 0xFFFFFFFF
        ]
        let bw = w / 7
        
        frameBuffer.withUnsafeMutableBufferPointer { fbPtr in
            for y in 0..<h {
                for i in 0..<7 {
                    let col = bars[i]
                    for x in (i * bw)..<((i + 1) * bw) {
                        let idx = y * maxWidth + (x * 2)
                        fbPtr[idx] = col
                        fbPtr[idx + 1] = col
                    }
                }
            }
        }
    }
    
    
    func drawGridTestPattern() {
        let h = 224, w = 256
        
        frameBuffer.withUnsafeMutableBufferPointer { fbPtr in
            for y in 0..<h {
                for x in 0..<w {
                    let isG = (x % 8 == 0) || (y % 8 == 0)
                    let c: UInt32 = isG ? 0xFFFFFFFF : 0xFF202020
                    let idx = y * maxWidth + (x * 2)
                    fbPtr[idx] = c
                    fbPtr[idx + 1] = c
                }
            }
        }
    }
}
