import Foundation

class GSU {
    var regs = [UInt16](repeating: 0, count: 16)
    var sfr: UInt16 = 0
    var pbr: UInt8 = 0
    var rombr: UInt8 = 0
    var ram = [UInt8](repeating: 0, count: 64 * 1024)
    var cache = [UInt8](repeating: 0, count: 512)
    var isRunning = false
    
    weak var bus: Bus?
    
    func reset() {
        regs = [UInt16](repeating: 0, count: 16)
        sfr = 0; pbr = 0; rombr = 0
        isRunning = false
    }
    
    func read(_ addr: UInt32) -> UInt8 {
        if addr < UInt32(ram.count) { return ram[Int(addr)] }
        return 0
    }
    
    func write(_ addr: UInt32, data: UInt8) {
        if addr < UInt32(ram.count) { ram[Int(addr)] = data }
    }
    
    func step() {
        if !isRunning { return }
        let pc = UInt32(pbr) << 16 | UInt32(regs[15])
        let opcode = fetch(pc)
        regs[15] &+= 1
        execute(opcode)
    }
    
    func fetch(_ addr: UInt32) -> UInt8 {
        if let bus = bus, let cart = bus.cartridge { return cart.read(addr) }
        return 0
    }
    
    func execute(_ op: UInt8) {
        switch op {
        case 0x00: isRunning = false
        case 0x01: break
        
        case 0x04:
            let s = Int32(Int16(bitPattern: regs[regs[14] == 0 ? 0 : Int(op >> 4)]))
            let m = Int32(Int16(bitPattern: regs[6]))
            let res = s * m
            regs[Int(op >> 4)] = UInt16(bitPattern: Int16(truncatingIfNeeded: res))
            
        case 0x50 ... 0x5F:
            let d = Int(op & 0xF)
            let res = UInt32(regs[d]) &+ UInt32(regs[12])
            setFlags(res, isWord: true)
            regs[d] = UInt16(res & 0xFFFF)
            
        case 0x60 ... 0x6F:
            let d = Int(op & 0xF)
            let res = Int32(regs[d]) &- Int32(regs[12])
            setFlags(UInt32(bitPattern: res), isWord: true)
            regs[d] = UInt16(bitPattern: Int16(truncatingIfNeeded: res))
            
        case 0x20 ... 0x2F:
            let d = Int(op & 0xF)
            regs[d] = regs[12]
            setFlags(UInt32(regs[d]), isWord: true)
            
        case 0x4C:
            let x = Int(regs[1]); let y = Int(regs[2])
            let addr = y * 256 + x
            if addr < ram.count { ram[addr] = UInt8(regs[0] & 0xFF) }
            regs[1] &+= 1
            
        case 0x05 ... 0x0F:
            let cond: Bool
            switch op {
            case 0x05: cond = (sfr & 0x8000) == 0
            case 0x06: cond = (sfr & 0x8000) != 0
            case 0x07: cond = (sfr & 0x4000) != 0
            case 0x08: cond = (sfr & 0x4000) == 0
            case 0x09: cond = (sfr & 0x0002) == 0
            case 0x0A: cond = (sfr & 0x0002) != 0
            default: cond = true
            }
            let offset = Int8(bitPattern: fetch(UInt32(pbr) << 16 | UInt32(regs[15])))
            regs[15] &+= 1
            if cond {
                regs[15] = UInt16(bitPattern: Int16(truncatingIfNeeded: Int(regs[15]) + Int(offset)))
            }
            
        default: break
        }
    }
    
    func setFlags(_ res: UInt32, isWord: Bool) {
        if res == 0 { sfr |= 0x0002 } else { sfr &= ~0x0002 }
        if (res & 0x8000) != 0 { sfr |= 0x8000 } else { sfr &= ~0x8000 }
    }
}
