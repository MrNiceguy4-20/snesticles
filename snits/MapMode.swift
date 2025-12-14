import Foundation

final class Bus {
    // Dependencies
    weak var system: SNESSystem?
    var cpu: CPU!
    var ppu: PPU!
    var apu: APU!
    var cartridge: Cartridge!
    var dma: DMAController!
    var gsu: GSU!
    
    // Memory
    var wram = [UInt8](repeating: 0, count: 0x20000)
    
    // Registers
    private var wramAddr: UInt32 = 0
    private var multiplicandA: UInt8 = 0
    private var multiplicandB: UInt8 = 0
    private var dividend: UInt16 = 0
    private var divisor: UInt8 = 0
    private var quotient: UInt16 = 0
    private var multiplicationResult: UInt16 = 0
    private var remainder: UInt16 = 0
    
    // Input
    var joypad1: UInt16 = 0
    private var controller1Shift: UInt16 = 0
    private var controllerLatch: Bool = false
    
    init(ppu: PPU, apu: APU) {
        self.ppu = ppu
        self.apu = apu
        self.gsu = GSU()
        self.gsu.bus = self
    }
    
    func insertCartridge(_ cart: Cartridge) {
        self.cartridge = cart
    }
    
    func reset() {
        wram = [UInt8](repeating: 0, count: 0x20000)
        wramAddr = 0
        multiplicandA = 0xFF; multiplicandB = 0xFF
        dividend = 0; divisor = 0
        quotient = 0; multiplicationResult = 0; remainder = 0
        controllerLatch = false
        controller1Shift = 0
        gsu.reset()
    }
    
    // MARK: - Save/Load
    func save(to s: Serializer) {
        s.write(wram)
        s.write(wramAddr)
        s.write(multiplicandA); s.write(multiplicandB)
        s.write(dividend); s.write(divisor)
        s.write(quotient); s.write(multiplicationResult); s.write(remainder)
    }
    
    func load(from s: Serializer) {
        wram = s.readBytes(count: 0x20000)
        wramAddr = s.readUInt32()
        multiplicandA = s.readUInt8(); multiplicandB = s.readUInt8()
        dividend = s.readUInt16(); divisor = s.readUInt8()
        quotient = s.readUInt16(); multiplicationResult = s.readUInt16(); remainder = s.readUInt16()
    }
    
    // MARK: - Read
    @inline(__always)
    func read(_ addr: UInt32) -> UInt8 {
        let bank = UInt8((addr >> 16) & 0xFF)
        let offset = UInt16(addr & 0xFFFF)
        
        if bank == 0x7E || bank == 0x7F {
            return wram[Int(addr & 0x1FFFF)]
        }
        
        if (bank & 0x40) == 0 {
            if offset < 0x2000 { return wram[Int(offset)] }
            if offset < 0x6000 { return readIO(offset) }
        }
        
        if let cart = cartridge { return cart.read(bank, offset) }
        return 0
    }
    
    // MARK: - Write
    // Fixed: Removed 'data' label requirement to match internal calls
    @inline(__always)
    func write(_ addr: UInt32, _ data: UInt8) {
        let bank = UInt8((addr >> 16) & 0xFF)
        let offset = UInt16(addr & 0xFFFF)
        
        if bank == 0x7E || bank == 0x7F {
            wram[Int(addr & 0x1FFFF)] = data
            return
        }
        
        if (bank & 0x40) == 0 {
            if offset < 0x2000 { wram[Int(offset)] = data; return }
            if offset < 0x6000 { writeIO(offset, data); return }
        }
        
        cartridge?.write(bank, offset, data)
    }
    
    func readWord(_ addr: UInt32) -> UInt16 {
        let lo = UInt16(read(addr))
        let hi = UInt16(read(addr &+ 1))
        return (hi << 8) | lo
    }
    
    func writeWord(_ addr: UInt32, _ data: UInt16) {
        write(addr, UInt8(data & 0xFF))
        write(addr &+ 1, UInt8(data >> 8))
    }
    
    // MARK: - I/O
    private func readIO(_ offset: UInt16) -> UInt8 {
        switch offset {
        case 0x2100...0x213F: return ppu.read(offset)
        case 0x2140...0x2143: return apu.readPort(Int(offset - 0x2140))
        case 0x2180:
            let val = wram[Int(wramAddr & 0x1FFFF)]
            wramAddr = (wramAddr + 1) & 0x1FFFF
            return val
        case 0x4016:
            let bit = (controller1Shift >> 15) & 1
            if !controllerLatch { controller1Shift <<= 1 }
            return UInt8(bit)
        case 0x4210:
            var val: UInt8 = 0x02
            if ppu.nmiFlag { val |= 0x80 }
            ppu.nmiFlag = false
            return val
        case 0x4211:
            var val: UInt8 = 0
            if ppu.irqFlag { val |= 0x80 }
            ppu.irqFlag = false
            return val
        case 0x4214: return UInt8(quotient & 0xFF)
        case 0x4215: return UInt8(quotient >> 8)
        case 0x4216: return UInt8(multiplicationResult & 0xFF)
        case 0x4217: return UInt8(multiplicationResult >> 8)
        case 0x4300...0x437F: return dma.read(offset)
        default: return 0
        }
    }
    
    private func writeIO(_ offset: UInt16, _ data: UInt8) {
        switch offset {
        case 0x2100...0x213F: ppu.write(offset, data)
        case 0x2140...0x2143: apu.writePort(Int(offset - 0x2140), data)
        case 0x2180:
            wram[Int(wramAddr & 0x1FFFF)] = data
            wramAddr = (wramAddr + 1) & 0x1FFFF
        case 0x2181: wramAddr = (wramAddr & 0xFFFF00) | UInt32(data)
        case 0x2182: wramAddr = (wramAddr & 0xFF00FF) | (UInt32(data) << 8)
        case 0x2183: wramAddr = (wramAddr & 0x00FFFF) | (UInt32(data & 1) << 16)
        case 0x4016:
            let latch = (data & 1) != 0
            if controllerLatch && !latch { controller1Shift = joypad1 }
            controllerLatch = latch
        case 0x4200:
            ppu.nmiEnabled = (data & 0x80) != 0
            ppu.irqEnabled = (data & 0x30) != 0
        case 0x4202: multiplicandA = data
        case 0x4203:
            multiplicandB = data
            multiplicationResult = UInt16(multiplicandA) * UInt16(multiplicandB)
            remainder = multiplicationResult
        case 0x4204: dividend = (dividend & 0xFF00) | UInt16(data)
        case 0x4205: dividend = (dividend & 0x00FF) | (UInt16(data) << 8)
        case 0x4206:
            divisor = data
            if divisor == 0 { quotient = 0xFFFF; remainder = dividend }
            else { quotient = dividend / UInt16(divisor); remainder = dividend % UInt16(divisor) }
        case 0x420B: dma.startGDMA(data)
        case 0x420C: dma.enableHDMA(data)
        case 0x4300...0x437F: dma.write(offset, data)
        default: break
        }
    }
}
