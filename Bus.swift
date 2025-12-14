import Foundation

enum MapMode { case loRom, hiRom }

class Bus {
    var ram = Array<UInt8>(repeating: 0, count: 128 * 1024)
    var cartridge: Cartridge?
    var ppu: PPU
    var apu: APU
    var dmaController = DMAController()
    var dsp1 = DSP1()
    var gsu = GSU()
    var cheatEngine = CheatEngine()
    
    weak var system: SNESSystem?
    var joypad1_shift: UInt16 = 0
    var joypad_strobe: Bool = false
    var mapMode: MapMode = .loRom
    var irqEnabled: Bool = false; var irqVEnable: Bool = false; var irqHEnable: Bool = false
    var irqHTarget: UInt16 = 0x1FF; var irqVTarget: UInt16 = 0x1FF
    
    var regionPatch: UInt8 = 0
    var nmiStatus: UInt8 = 0 // Tracks the NMI Flag Status ($4212)
    
    init(ppu: PPU, apu: APU) {
        self.ppu = ppu; self.apu = apu
        self.ppu.bus = self // <--- FIX 1: Establish PPU back-reference for NMI signal
        self.gsu.bus = self
    }
    
    func save(_ s: Serializer) {
        s.writeBytes(ram)
        s.writeBool(irqEnabled)
        s.write8(nmiStatus)
    }
    
    func load(_ s: Serializer) {
        ram = s.readBytes(128 * 1024)
        irqEnabled = s.readBool()
        nmiStatus = s.read8()
    }
    
    func insertCartridge(_ cart: Cartridge) {
        self.cartridge = cart
        if cart.romData.count > 0x8000 {
            mapMode = (cart.romType & 0x01) != 0 ? .hiRom : .loRom

            
            let region = cart.read(mapMode == .loRom ? 0x7FD9 : 0xFFD9)
            if region >= 0x02 && region <= 0x0C {
                regionPatch = 0x10
            } else {
                regionPatch = 0x00
            }
        }
        dsp1.reset()
        gsu.reset()
        cheatEngine.clear()
    }

    // Method for PPU/System to set the NMI flag when VBLANK occurs
    func setNmiFlag() {
        self.nmiStatus |= 0x80
    }
    
    func checkIRQ(vCounter: UInt16, hCounter: UInt16) -> Bool {
        if !irqEnabled { return false }
        if irqVEnable && irqHEnable { return (vCounter == irqVTarget) && (hCounter == irqHTarget) }
        else if irqVEnable { return (vCounter == irqVTarget) && (hCounter == 0) }
        else if irqHEnable { return (hCounter == irqHTarget) }
        return false
    }
    
    func read(_ addr: UInt32) -> UInt8 {
        let bank = Int((addr >> 16) & 0xFF)
        let offset = Int(addr & 0xFFFF)

        // APU ports appear ONLY in banks 00–3F and 80–BF
        if (bank <= 0x3F || (bank >= 0x80 && bank <= 0xBF)) &&
           offset >= 0x2140 && offset <= 0x2143 {
            return apu.read(offset - 0x2140)
        }

        let val = internalRead(addr)  // <-- must receive full 24-bit address!
        return cheatEngine.patch(addr: addr, val: val)
    }


    private func internalRead(_ addr: UInt32) -> UInt8 {
        let bank = (addr >> 16) & 0xFF; let offset = addr & 0xFFFF
        
        if (cartridge?.hasGSU == true) {
            if (bank <= 0x3F || (bank >= 0x80 && bank <= 0xBF)) && offset >= 0x3000 && offset < 0x3300 {
                return gsu.read(UInt32(offset - 0x3000))
            }
            if bank >= 0x00 && bank <= 0x3F && offset >= 0x6000 && offset < 0x8000 {
                return gsu.read(UInt32(offset - 0x6000))
            }
        }
        
        if (cartridge?.hasDSP1 == true) {
            if mapMode == .loRom && (bank <= 0x3F || (bank >= 0x80 && bank <= 0xBF)) && offset >= 0x6000 && offset < 0x8000 {
                if offset == 0x6000 { return dsp1.readData() }
                if offset == 0x7000 { return dsp1.readStatus() }
            }
            if mapMode == .hiRom && (bank <= 0x1F || (bank >= 0x80 && bank <= 0x9F)) && offset >= 0x6000 && offset < 0x8000 {
                if offset == 0x6000 { return dsp1.readData() }
                if offset == 0x7000 { return dsp1.readStatus() }
            }
        }
        
        if bank == 0x7E || bank == 0x7F { return ram[Int(offset & 0x1FFFF)] }
        if (bank <= 0x3F) || (bank >= 0x80 && bank <= 0xBF) {
            if offset < 0x2000 { return ram[Int(offset)] }
            if offset >= 0x2100 && offset <= 0x5FFF {
                if offset >= 0x2140 && offset <= 0x2143 { return apu.read(Int(offset - 0x2140)) }
                if offset == 0x213F {
                    var val: UInt8 = 0x00
                    if regionPatch != 0 { val |= regionPatch }
                    return val
                }
                if offset == 0x4016 {
                    let bit = (joypad1_shift & 0x8000) != 0 ? 1 : 0
                    if !joypad_strobe { joypad1_shift = joypad1_shift << 1 }; return UInt8(bit)
                }
                // $4212 read logic: Read status and CLEAR NMI flag (Bit 7)
                if offset == 0x4212 {
                    let status = self.nmiStatus
                    self.nmiStatus &= 0x7F // Clear NMI flag bit on read
                    // H/V Counter read logic is typically included here (Bits 0-6).
                    // Returning only the status flag bits for now.
                    return status
                }
                if offset >= 0x4300 && offset <= 0x437F { return dmaController.read(offset) }
                return ppu.readRegister(offset)
            }
            if mapMode == .loRom && bank >= 0x70 && bank <= 0x7D && offset < 0x8000 {
                return cartridge?.readSRAM(offset) ?? 0xFF
            }
            if mapMode == .hiRom && bank >= 0x20 && bank <= 0x3F && offset >= 0x6000 && offset < 0x8000 {
                return cartridge?.readSRAM(offset - 0x6000) ?? 0xFF
            }
        }

        if mapMode == .loRom {
            if (bank & 0x7F) <= 0x7D && offset >= 0x8000 {
                let romOffset = (UInt32(bank & 0x7F) * 0x8000) + (offset - 0x8000)
                return cartridge?.read(romOffset) ?? 0xEA
            }
        } else {
            if (bank & 0x7F) >= 0x40 { return cartridge?.read(addr & 0x3FFFFF) ?? 0xEA }
        }
        return 0xFF
    }
    
    func write(_ addr: UInt32, data: UInt8) {
        let bank = (addr >> 16) & 0xFF; let offset = addr & 0xFFFF
        
        if (cartridge?.hasGSU == true) {
            if (bank <= 0x3F || (bank >= 0x80 && bank <= 0xBF)) && offset >= 0x3000 && offset < 0x3300 {
                gsu.write(UInt32(offset - 0x3000), data: data); return
            }
        }
        
        if (cartridge?.hasDSP1 == true) {
            if mapMode == .loRom && (bank <= 0x3F || (bank >= 0x80 && bank <= 0xBF)) && offset >= 0x6000 && offset < 0x8000 {
                if offset == 0x6000 { dsp1.writeData(data); return }
            }
            if mapMode == .hiRom && (bank <= 0x1F || (bank >= 0x80 && bank <= 0x9F)) && offset >= 0x6000 && offset < 0x8000 {
                if offset == 0x6000 { dsp1.writeData(data); return }
            }
        }
        
        if bank == 0x7E || bank == 0x7F { ram[Int(offset & 0x1FFFF)] = data; return }
        if (bank <= 0x3F) || (bank >= 0x80 && bank <= 0xBF) {
            if offset < 0x2000 { ram[Int(offset)] = data; return }
            if offset >= 0x2100 && offset <= 0x5FFF {
                if offset >= 0x2140 && offset <= 0x2143 { apu.write(Int(offset - 0x2140), data: data); return }
                if offset == 0x4200 {
                    ppu.nmiEnabled = (data & 0x80) != 0; irqVEnable = (data & 0x20) != 0
                    irqHEnable = (data & 0x10) != 0; irqEnabled = irqVEnable || irqHEnable; return
                }
                if offset == 0x4016 {
                    let newStrobe = (data & 0x01) != 0
                    if joypad_strobe && !newStrobe { joypad1_shift = system?.currentInput ?? 0 }
                    joypad_strobe = newStrobe; return
                }
                if offset == 0x420B { dmaController.enableDMA(channels: data, bus: self); return }
                if offset == 0x420C { dmaController.enableHDMA(channels: data); return }
                if offset >= 0x4300 && offset <= 0x437F { dmaController.write(offset, data: data); return }
                ppu.writeRegister(offset, data: data); return
            }
            if mapMode == .loRom && bank >= 0x70 && bank <= 0x7D && offset < 0x8000 { cartridge?.writeSRAM(offset, data: data); return }
            if mapMode == .hiRom && bank >= 0x20 && bank <= 0x3F && offset >= 0x6000 && offset < 0x8000 { cartridge?.writeSRAM(offset - 0x6000, data: data); return }
        }
    }
    func readWord(_ addr: UInt32) -> UInt16 {
        let lo = UInt16(read(addr))
        let hi = UInt16(read(addr + 1))
        return lo | (hi << 8)
    }

    func writeWord(_ addr: UInt32, data: UInt16) { write(addr, data: UInt8(data & 0xFF)); write(addr + 1, data: UInt8(data >> 8)) }
}
