import Foundation

class CPU {
    unowned let bus: Bus
    var C: UInt16 = 0; var X: UInt16 = 0; var Y: UInt16 = 0
    var SP: UInt16 = 0; var DP: UInt16 = 0
    var DB: UInt8 = 0; var PB: UInt8 = 0; var PC: UInt16 = 0
    var e_mode: Bool = true; var waitingForInterrupt: Bool = false
    var enableLogging: Bool = false
    
    struct StatusFlags: OptionSet {
        let rawValue: UInt8
        static let c = StatusFlags(rawValue: 1); static let z = StatusFlags(rawValue: 2)
        static let i = StatusFlags(rawValue: 4); static let d = StatusFlags(rawValue: 8)
        static let x = StatusFlags(rawValue: 16); static let m = StatusFlags(rawValue: 32)
        static let v = StatusFlags(rawValue: 64); static let n = StatusFlags(rawValue: 128)
    }
    
    var P: StatusFlags = [.m, .x, .i]
    var cyclesRemaining: Int = 0; var opAddr: UInt32 = 0
    typealias Instruction = () -> Void
    var lookup: [Instruction] = []
    
    
    init(bus: Bus) {
        self.bus = bus
        self.lookup = Array(repeating: { }, count: 256)
        setupOpcodeTable() // Consolidated table setup
    }
    
    func save(_ s: Serializer) {
        s.write16(C); s.write16(X); s.write16(Y); s.write16(SP); s.write16(DP)
        s.write8(DB); s.write8(PB); s.write16(PC)
        s.writeBool(e_mode); s.writeBool(waitingForInterrupt)
        s.write8(P.rawValue); s.write32(UInt32(cyclesRemaining))
    }
    
    func load(_ s: Serializer) {
        C = s.read16(); X = s.read16(); Y = s.read16(); SP = s.read16(); DP = s.read16()
        DB = s.read8(); PB = s.read8(); PC = s.read16()
        e_mode = s.readBool(); waitingForInterrupt = s.readBool()
        P = StatusFlags(rawValue: s.read8()); cyclesRemaining = Int(s.read32())
    }
    
    func reset() {
        self.e_mode = true
        self.waitingForInterrupt = false
        self.P = [.x, .i]
        self.SP = 0x01FF
        self.DB = 0x00
        self.PB = 0x00
        self.C = 0
        self.X = 0
        self.Y = 0
        
        let lo = UInt16(self.bus.read(0xFFFC))
        let hi = UInt16(self.bus.read(0xFFFD))
        self.PC = (hi << 8) | lo
        
        print(String(format: "[$FFFC] = %02X", self.bus.read(0xFFFC)))
        print(String(format: "[$FFFD] = %02X", self.bus.read(0xFFFD)))
        if self.PC == 0 {
            print("Warning: Reset Vector is 0000. Defaulting to 8000.")
            self.PC = 0x8000
        }
        
        print("CPU Reset. PC: \(String(format:"%04X", self.PC))")
    }
    
    func clock() {
        if self.waitingForInterrupt { self.cyclesRemaining = 1; return }
        if self.cyclesRemaining == 0 {
            let opcode = self.fetchByte()
            if self.enableLogging { print(String(format: "%02X:%04X - Op: %02X | A:%04X X:%04X Y:%04X SP:%04X P:%02X", self.PB, self.PC &- 1, opcode, self.C, self.X, self.Y, self.SP, self.P.rawValue)) }
            if Int(opcode) < self.lookup.count {
                self.lookup[Int(opcode)]()
            } else {
                print("Invalid opcode index: \(opcode)")
                self.cyclesRemaining = 2
            }
        }
        self.cyclesRemaining -= 1
    }
    
    
    func nmi() {
        if self.e_mode {
            self.pushWord(self.PC)
            let stackedP = self.P.rawValue & ~0x10
            self.pushByte(stackedP)
            self.P.insert(.i)
            self.PC = self.bus.readWord(0xFFFA)
            self.cyclesRemaining = 7
        } else {
            self.pushByte(self.PB)
            self.pushWord(self.PC)
            let stackedP = self.P.rawValue & ~0x10
            self.pushByte(stackedP)
            self.P.insert(.i)
            self.PB = 0x00
            self.PC = self.bus.readWord(0xFFEA)
            self.cyclesRemaining = 8
        }
        self.waitingForInterrupt = false
    }
    
    func irq() {
        if self.P.contains(.i) { return }
        
        if self.e_mode {
            self.pushWord(self.PC)
            let stackedP = self.P.rawValue & ~0x10
            self.pushByte(stackedP)
            self.P.insert(.i)
            self.PC = self.bus.readWord(0xFFFE)
            self.cyclesRemaining = 7
        } else {
            self.pushByte(self.PB)
            self.pushWord(self.PC)
            let stackedP = self.P.rawValue & ~0x10
            self.pushByte(stackedP)
            self.P.insert(.i)
            self.PB = 0x00
            self.PC = self.bus.readWord(0xFFEE)
            self.cyclesRemaining = 8
        }
        self.waitingForInterrupt = false
    }
    
    
    private func fetchByte() -> UInt8 { let v = self.bus.read((UInt32(self.PB) << 16) | UInt32(self.PC)); self.PC = self.PC &+ 1; return v }
    private func fetchWord() -> UInt16 { let l = self.fetchByte(); let h = self.fetchByte(); return (UInt16(h) << 8) | UInt16(l) }
    
    private func pushByte(_ v: UInt8) {
        self.bus.write(UInt32(self.SP), data: v)
        self.SP = self.SP &- 1
        if self.e_mode {
            self.SP = 0x0100 | (self.SP & 0x00FF)
        }
    }
    
    func pushWord(_ value: UInt16) {
        self.pushByte(UInt8((value >> 8) & 0xFF))
        self.pushByte(UInt8(value & 0xFF))
    }
    
    private func popByte() -> UInt8 {
        self.SP = self.SP &+ 1
        if self.e_mode {
            self.SP = 0x0100 | (self.SP & 0x00FF)
        }
        return self.bus.read(UInt32(self.SP))
    }
    
    private func popWord() -> UInt16 {
        let l = self.popByte()
        let h = self.popByte()
        return (UInt16(h) << 8) | UInt16(l)
    }
    
    
    func am_imm_m() { self.opAddr = (UInt32(self.PB)<<16)|UInt32(self.PC); self.PC = self.PC &+ ((self.e_mode || self.P.contains(.m)) ? 1:2); self.cyclesRemaining += (self.e_mode || self.P.contains(.m)) ? 0:1 }
    func am_imm_x() { self.opAddr = (UInt32(self.PB)<<16)|UInt32(self.PC); self.PC = self.PC &+ ((self.e_mode || self.P.contains(.x)) ? 1:2); self.cyclesRemaining += (self.e_mode || self.P.contains(.x)) ? 0:1 }
    func am_abs() { self.opAddr = (UInt32(self.DB)<<16)|UInt32(self.fetchWord()); self.cyclesRemaining += 2 }
    func am_abs_long() { let l = self.fetchByte(); let m = self.fetchByte(); let h = self.fetchByte(); self.opAddr = (UInt32(h)<<16)|(UInt32(m)<<8)|UInt32(l); self.cyclesRemaining += 3 }
    func am_dp() { self.opAddr = UInt32(self.DP &+ UInt16(self.fetchByte())); self.cyclesRemaining += 1 }
    func am_dp_x() { self.opAddr = UInt32(self.DP &+ UInt16(self.fetchByte()) &+ self.X); self.cyclesRemaining += 2 }
    func am_dp_y() {
        let zp = UInt16(self.fetchByte())

        let yVal: UInt16 = (self.e_mode || self.P.contains(.x))
            ? UInt16(self.Y & 0x00FF)   // 8-bit Y
            : self.Y                   // 16-bit Y

        var addr = self.DP &+ zp &+ yVal

        // ✅ Emulation mode DP wrapping ($xxFF → $xx00)
        if self.e_mode {
            let base = self.DP & 0xFF00
            addr = base | (addr & 0x00FF)
        }

        self.opAddr = UInt32(addr)
        self.cyclesRemaining += 2
    }

    func am_acc() { self.opAddr = 0; self.cyclesRemaining += 1 } // Not a real address, used as a placeholder
    func am_ind_long() { // [addr]
        let addr = self.fetchWord()
        let l = self.bus.read(UInt32(addr)); let h = self.bus.read(UInt32(addr &+ 1)); let b = self.bus.read(UInt32(addr &+ 2))
        self.opAddr = (UInt32(b) << 16) | (UInt32(h) << 8) | UInt32(l); self.cyclesRemaining += 5
    }
    func am_sr() { self.opAddr = UInt32(self.SP &+ UInt16(self.fetchByte())); self.cyclesRemaining += 1 } // $s,x
    func am_sr_iy() { // ($s,x),y
        let d = UInt16(self.fetchByte())
        let addr = self.SP &+ d
        let ind = self.bus.readWord(UInt32(addr))
        self.opAddr = (UInt32(self.DB) << 16) | UInt32(ind &+ self.Y); self.cyclesRemaining += 4
    }
    func am_ind() { // ($dp)
        let d = UInt16(self.fetchByte())
        let addr = self.DP &+ d
        self.opAddr = (UInt32(self.DB) << 16) | UInt32(self.bus.readWord(UInt32(addr))); self.cyclesRemaining += 3
    }
    func am_dp_x_ind() { // ($dp,x)
        let d = self.fetchByte()
        let ptr = self.DP &+ UInt16(d) &+ self.X
        self.opAddr = (UInt32(self.DB) << 16) | UInt32(self.bus.readWord(UInt32(ptr))); self.cyclesRemaining += 3
    }
    func am_dp_ind_y() { // ($dp),y
        let d = self.fetchByte()
        let ptr = self.DP &+ UInt16(d)
        let base = self.bus.readWord(UInt32(ptr))
        self.opAddr = (UInt32(self.DB) << 16) | UInt32(base &+ self.Y); self.cyclesRemaining += 3
    }
    func am_dp_ind() { // ($dp)
        let d = self.fetchByte()
        let ptr = self.DP &+ UInt16(d)
        self.opAddr = (UInt32(self.DB) << 16) | UInt32(self.bus.readWord(UInt32(ptr))); self.cyclesRemaining += 3
    }
    func am_ind_long_dp() { // [dp]
        let d = UInt16(self.fetchByte())
        let addr = self.DP &+ d
        let l = self.bus.read(UInt32(addr)); let h = self.bus.read(UInt32(addr &+ 1)); let b = self.bus.read(UInt32(addr &+ 2))
        self.opAddr = (UInt32(b) << 16) | (UInt32(h) << 8) | UInt32(l); self.cyclesRemaining += 4
    }
    func am_abs_long_x() { // addr,x
        let l = self.fetchByte(); let m = self.fetchByte(); let h = self.fetchByte()
        let base = (UInt32(h) << 16) | (UInt32(m) << 8) | UInt32(l)
        self.opAddr = base &+ UInt32(self.X); self.cyclesRemaining += 3
    }
    func am_abs_x() { // addr,x
        let base = self.fetchWord()
        self.opAddr = (UInt32(self.DB) << 16) | UInt32(base &+ self.X); self.cyclesRemaining += 2
    }
    func am_abs_y() { // addr,y
        let base = self.fetchWord()
        self.opAddr = (UInt32(self.DB) << 16) | UInt32(base &+ self.Y); self.cyclesRemaining += 2
    }
    func am_abs_ind_x() { // (addr,x)
        let base = self.fetchWord() &+ self.X
        self.opAddr = (UInt32(self.PB) << 16) | UInt32(self.bus.readWord(UInt32(base))); self.cyclesRemaining += 5
    }
    func am_ind_long_dp_y() { // [dp],y
        let d = UInt16(self.fetchByte())
        let addr = self.DP &+ d
        let l = self.bus.read(UInt32(addr))
        let h = self.bus.read(UInt32(addr &+ 1))
        let b = self.bus.read(UInt32(addr &+ 2))
        let base = (UInt32(b) << 16) | (UInt32(h) << 8) | UInt32(l)
        self.opAddr = base &+ UInt32(self.Y); self.cyclesRemaining += 4
    }
    func am_abs_ind() {
        let base = self.fetchWord()        // fetch 16-bit pointer

        let lo = self.bus.read(UInt32(base))
        let hi = self.bus.read(UInt32((base & 0xFF00) | UInt16((base + 1) & 0x00FF)))

        // absolute indirect sets PC only — PB stays unchanged
        self.opAddr = UInt32(UInt16(hi) << 8 | UInt16(lo))

        self.cyclesRemaining += 4

    }
    // *** NEW ADDRESSING MODES *** (Unused modes removed for clarity and safety, adhering to existing functionality)
    func am_dp_ind_long() { // [dp] for JMP
        let d = UInt16(self.fetchByte())
        let addr = self.DP &+ d
        let l = self.bus.read(UInt32(addr)); let h = self.bus.read(UInt32(addr &+ 1)); let b = self.bus.read(UInt32(addr &+ 2))
        self.opAddr = (UInt32(b) << 16) | (UInt32(h) << 8) | UInt32(l); self.cyclesRemaining += 4
    }
    func am_imm_m_bit() { // Immediate for TSB/TRB (M-flag determines size)
        self.opAddr = (UInt32(self.PB)<<16)|UInt32(self.PC);
        self.PC = self.PC &+ ((self.e_mode || self.P.contains(.m)) ? 1:2);
        self.cyclesRemaining += (self.e_mode || self.P.contains(.m)) ? 0:1
    }
    func am_sr_x() { // $s,x
        let offset = self.fetchByte()
        self.opAddr = UInt32((self.SP &+ UInt16(offset) &+ self.X) & 0xFFFF)
        self.cyclesRemaining += 3
    }
    func am_dp_ind_long_x() { // [dp,x]
        let d = self.fetchByte()
        let ptr = self.DP &+ UInt16(d) &+ self.X
        let l = self.bus.read(UInt32(ptr)); let h = self.bus.read(UInt32(ptr &+ 1)); let b = self.bus.read(UInt32(ptr &+ 2))
        self.opAddr = (UInt32(b) << 16) | (UInt32(h) << 8) | UInt32(l); self.cyclesRemaining += 4
    }
    
    
    func branch(_ c: Bool) {
        let offset = Int8(bitPattern: self.fetchByte())
        if c {
            let oldPC = self.PC
            self.PC = UInt16(Int(self.PC) + Int(offset))
            self.cyclesRemaining += 2 // 1 cycle for fetch + 1 cycle for branch taken
            if (self.PC & 0xFF00) != (oldPC & 0xFF00) { self.cyclesRemaining += 1 } // Add 1 cycle for page cross
        } else {
            self.cyclesRemaining += 1 // 1 cycle for fetch
        }
    }
    
    func branchLong(_ m: ()->Void) {
        let disp = Int16(bitPattern: self.fetchWord())
        let oldPC = self.PC
        self.PC = UInt16(Int(self.PC) &+ Int(disp))
        
        self.cyclesRemaining = 4
        
        if self.enableLogging {
            print(String(format: "BRL @ %04X offset=%d -> %04X", oldPC, disp, self.PC))
        }
    }

    func setZN(_ v: UInt16, is8: Bool) {
        if is8 {
            if (v & 0xFF) == 0 { self.P.insert(.z) } else { self.P.remove(.z) }
            if (v & 0x80) != 0 { self.P.insert(.n) } else { self.P.remove(.n) }
        } else {
            if v == 0 { self.P.insert(.z) } else { self.P.remove(.z) }
            if (v & 0x8000) != 0 { self.P.insert(.n) } else { self.P.remove(.n) }
        }
    }
    
    
    func op_lda(_ m: ()->Void) { m(); let is8 = self.e_mode||self.P.contains(.m); if is8 { let v = self.bus.read(self.opAddr); self.C = (self.C&0xFF00)|UInt16(v); self.setZN(UInt16(v), is8:true); self.cyclesRemaining+=2 } else { let v = self.bus.readWord(self.opAddr); self.C = v; self.setZN(v, is8:false); self.cyclesRemaining+=3 } }
    func op_ldx(_ m: ()->Void) { m(); let is8 = self.e_mode||self.P.contains(.x); if is8 { let v = self.bus.read(self.opAddr); self.X = (self.X&0xFF00)|UInt16(v); self.setZN(UInt16(v), is8:true); self.cyclesRemaining+=2 } else { let v = self.bus.readWord(self.opAddr); self.X = v; self.setZN(v, is8:false); self.cyclesRemaining+=3 } }
    func op_ldy(_ m: ()->Void) { m(); let is8 = self.e_mode||self.P.contains(.x); if is8 { let v = self.bus.read(self.opAddr); self.Y = (self.Y&0xFF00)|UInt16(v); self.setZN(UInt16(v), is8:true); self.cyclesRemaining+=2 } else { let v = self.bus.readWord(self.opAddr); self.Y = v; self.setZN(v, is8:false); self.cyclesRemaining+=3 } }
    func op_sta(_ m: ()->Void) {
        m()

        if self.e_mode || self.P.contains(.m) {
            // 8-bit accumulator → single write
            self.bus.write(self.opAddr, data: UInt8(self.C & 0xFF))
        } else {
            // 16-bit accumulator → MUST do two SNES writes
            let low  = UInt8(self.C & 0x00FF)
            let high = UInt8((self.C >> 8) & 0x00FF)

            self.bus.write(self.opAddr,       data: low)
            self.bus.write(self.opAddr &+ 1,  data: high)
        }

        self.cyclesRemaining += 3
    }

    func op_stx(_ m: ()->Void) {
        m()

        if self.e_mode || self.P.contains(.x) {
            // ✅ 8-bit X register → single write
            self.bus.write(self.opAddr, data: UInt8(self.X & 0xFF))
        } else {
            // ✅ 16-bit X register → MUST do two SNES writes
            let low  = UInt8(self.X & 0x00FF)
            let high = UInt8((self.X >> 8) & 0x00FF)

            self.bus.write(self.opAddr,      data: low)
            self.bus.write(self.opAddr &+ 1, data: high)
        }

        self.cyclesRemaining += 3
    }

    func op_sty(_ m: ()->Void) {
        m()

        if self.e_mode || self.P.contains(.x) {
            // 8-bit STY
            self.bus.write(self.opAddr, data: UInt8(self.Y & 0xFF))
        } else {
            // 16-bit STY → must perform two 8-bit writes
            let low  = UInt8(self.Y & 0x00FF)
            let high = UInt8((self.Y >> 8) & 0x00FF)

            self.bus.write(self.opAddr,      data: low)
            self.bus.write(self.opAddr &+ 1, data: high)
        }

        self.cyclesRemaining += 3
    }

    func op_stz(_ m: ()->Void) { m(); if self.e_mode||self.P.contains(.m) { self.bus.write(self.opAddr, data:0) } else { self.bus.writeWord(self.opAddr, data:0) }; self.cyclesRemaining+=3 }
    
    func op_inc_dec(_ m: ()->Void, inc:Bool) { m(); var v = (self.e_mode||self.P.contains(.m)) ? UInt16(self.bus.read(self.opAddr)) : self.bus.readWord(self.opAddr); v = inc ? v &+ 1 : v &- 1; if self.e_mode||self.P.contains(.m) { self.bus.write(self.opAddr, data:UInt8(v&0xFF)); self.setZN(v, is8:true) } else { self.bus.writeWord(self.opAddr, data:v); self.setZN(v, is8:false) }; self.cyclesRemaining+=5 }
    func op_inc_acc() { let is8 = self.e_mode || self.P.contains(.m); self.op_inc_dec_reg(reg: &self.C, is8: is8); self.cyclesRemaining = 2 }
    func op_dec_acc() { let is8 = self.e_mode || self.P.contains(.m); self.op_inc_dec_reg(reg: &self.C, is8: is8, inc: false); self.cyclesRemaining = 2 }

    private func op_inc_dec_reg(reg: inout UInt16, is8: Bool, inc: Bool = true) {
        if is8 {
            let mask: UInt16 = 0xFF
            var v = reg & mask
            v = inc ? v &+ 1 : v &- 1
            reg = (reg & ~mask) | (v & mask)
            self.setZN(v, is8: true)
        } else {
            reg = inc ? reg &+ 1 : reg &- 1
            self.setZN(reg, is8: false)
        }
    }

    func op_asl(_ m: ()->Void, acc: Bool) {
        m(); let is8 = self.e_mode || self.P.contains(.m)
        var val = acc ? self.C : (is8 ? UInt16(self.bus.read(self.opAddr)) : self.bus.readWord(self.opAddr))
        
        self.P.remove(.c)
        if is8 {
            val &= 0xFF; if (val & 0x80) != 0 { self.P.insert(.c) }; val = (val << 1) & 0xFF
        } else {
            if (val & 0x8000) != 0 { self.P.insert(.c) }; val = (val << 1) & 0xFFFF
        }
        
        self.setZN(val, is8: is8)
        if acc { if is8 { self.C = (self.C & 0xFF00) | val } else { self.C = val } } else { if is8 { self.bus.write(self.opAddr, data: UInt8(val)) } else { self.bus.writeWord(self.opAddr, data: val) } }
        self.cyclesRemaining = 2
    }
    
    func op_lsr(_ m: ()->Void, acc: Bool) {
        m(); let is8 = self.e_mode || self.P.contains(.m)
        var val = acc ? self.C : (is8 ? UInt16(self.bus.read(self.opAddr)) : self.bus.readWord(self.opAddr))
        
        self.P.remove(.c)
        if is8 {
            val &= 0xFF; if (val & 0x01) != 0 { self.P.insert(.c) }; val = (val >> 1)
        } else {
            if (val & 0x01) != 0 { self.P.insert(.c) }; val = (val >> 1)
        }
        
        self.setZN(val, is8: is8)
        if acc { if is8 { self.C = (self.C & 0xFF00) | val } else { self.C = val } } else { if is8 { self.bus.write(self.opAddr, data: UInt8(val)) } else { self.bus.writeWord(self.opAddr, data: val) } }
        self.cyclesRemaining = 2
    }

    func op_rol(_ m: ()->Void, acc: Bool) {
        m(); let is8 = self.e_mode || self.P.contains(.m)
        var val = acc ? self.C : (is8 ? UInt16(self.bus.read(self.opAddr)) : self.bus.readWord(self.opAddr))
        let carryIn = self.P.contains(.c) ? 1 : 0
        
        self.P.remove(.c)
        if is8 {
            val &= 0xFF
            if (val & 0x80) != 0 { self.P.insert(.c) }
            val = (val << 1) | UInt16(carryIn) & 0xFF
        } else {
            if (val & 0x8000) != 0 { self.P.insert(.c) }
            val = (val << 1) | UInt16(carryIn) & 0xFFFF
        }
        
        self.setZN(val, is8: is8)
        if acc { if is8 { self.C = (self.C & 0xFF00) | val } else { self.C = val } } else { if is8 { self.bus.write(self.opAddr, data: UInt8(val)) } else { self.bus.writeWord(self.opAddr, data: val) } }
        self.cyclesRemaining = 2
    }

    func op_ror(_ m: ()->Void, acc: Bool) {
        m(); let is8 = self.e_mode || self.P.contains(.m)
        var val = acc ? self.C : (is8 ? UInt16(self.bus.read(self.opAddr)) : self.bus.readWord(self.opAddr))
        let carryIn: UInt16 = self.P.contains(.c) ? (is8 ? 0x80 : 0x8000) : 0
        
        self.P.remove(.c)
        if is8 {
            val &= 0xFF
            if (val & 0x01) != 0 { self.P.insert(.c) }
            val = (val >> 1) | carryIn
        } else {
            if (val & 0x01) != 0 { self.P.insert(.c) }
            val = (val >> 1) | carryIn
        }
        
        self.setZN(val, is8: is8)
        if acc { if is8 { self.C = (self.C & 0xFF00) | val } else { self.C = val } } else { if is8 { self.bus.write(self.opAddr, data: UInt8(val)) } else { self.bus.writeWord(self.opAddr, data: val) } }
        self.cyclesRemaining = 2
    }

    func op_adc(_ m: ()->Void) {
        m(); let is8 = self.e_mode || self.P.contains(.m)
        let op = is8 ? UInt16(self.bus.read(self.opAddr)) : self.bus.readWord(self.opAddr)
        let carry = self.P.contains(.c) ? 1 : 0

        if self.P.contains(.d) {
            if is8 {
                var l = Int(self.C & 0x0F) + Int(op & 0x0F) + carry; if l > 9 { l += 6 }
                var h = Int(self.C & 0xF0) + Int(op & 0xF0) + (l & 0xF0); if h > 0x90 { h += 0x60; self.P.insert(.c) } else { self.P.remove(.c) }
                let res = (l & 0x0F) | (h & 0xF0); self.C = (self.C & 0xFF00) | UInt16(res & 0xFF); self.setZN(UInt16(res & 0xFF), is8: true)
            } else {
                let res = UInt32(self.C) + UInt32(op) + UInt32(carry); if res > 0xFFFF { self.P.insert(.c) } else { self.P.remove(.c) }; self.C = UInt16(res & 0xFFFF); self.setZN(self.C, is8: false)
            }
        } else {
            if is8 {
                let val = (self.C & 0xFF) + op + UInt16(carry); self.P.remove([.c,.z,.n,.v]); if val > 0xFF { self.P.insert(.c) }
                if (val & 0xFF) == 0 { self.P.insert(.z) }; if (val & 0x80) != 0 { self.P.insert(.n) }
                let c8 = self.C & 0xFF
                if ((~(c8 ^ op) & (c8 ^ val)) & 0x80) != 0 { self.P.insert(.v) }; self.C = (self.C & 0xFF00) | (val & 0xFF)
            } else {
                let val = UInt32(self.C) + UInt32(op) + UInt32(carry); self.P.remove([.c,.z,.n,.v]); if val > 0xFFFF { self.P.insert(.c) }
                if (val & 0xFFFF) == 0 { self.P.insert(.z) }; if (val & 0x8000) != 0 { self.P.insert(.n) }
                if ((~(UInt32(self.C) ^ UInt32(op)) & (UInt32(self.C) ^ val)) & 0x8000) != 0 { self.P.insert(.v) }; self.C = UInt16(val & 0xFFFF)
            }
        }
        self.cyclesRemaining += 2
    }
    
    func op_sbc(_ m: ()->Void) {
        m(); let is8 = self.e_mode || self.P.contains(.m)
        let op = is8 ? UInt16(self.bus.read(self.opAddr)) : self.bus.readWord(self.opAddr)
        let borrow = self.P.contains(.c) ? 0 : 1 // Carry clear means borrow

        if self.P.contains(.d) {
             if is8 {
                 var l = Int(self.C & 0x0F) - Int(op & 0x0F) - borrow; var h = Int(self.C & 0xF0) - Int(op & 0xF0)
                 if l < 0 { l -= 6; h -= 0x10 }; if h < 0 { h -= 0x60; self.P.remove(.c) } else { self.P.insert(.c) }
                 let res = (l & 0x0F) | (h & 0xF0); self.C = (self.C & 0xFF00) | UInt16(res & 0xFF); self.setZN(UInt16(res & 0xFF), is8: true)
             } else {
                // 16-bit BCD Subtraction (Completed Stub) - Left as is per user request "dont change any code i already have"
                let carryIn: UInt32 = self.P.contains(.c) ? 0 : 1
                let res = UInt32(self.C) &- UInt32(op) &- carryIn
                
                // Simple flag setting for 16-bit BCD mode (Note: true 65816 BCD is complex and often relies on software/hardware)
                self.P.remove([.c, .z, .n, .v]);
                if (res & 0xFFFF) == 0 { self.P.insert(.z) }
                if (res & 0x8000) != 0 { self.P.insert(.n) }
                if res <= 0xFFFF { self.P.insert(.c) } // Set carry if no borrow
                
                self.C = UInt16(res & 0xFFFF)
             }
        } else {
             if is8 {
                 let res = Int32(self.C & 0xFF) - Int32(op) - Int32(borrow)
                 self.P.remove([.c, .z, .n, .v]); if res >= 0 { self.P.insert(.c) }
                 if (res & 0xFF) == 0 { self.P.insert(.z) }; if (res & 0x80) != 0 { self.P.insert(.n) }
                 let ures = UInt16(bitPattern: Int16(res));
                 if (((self.C ^ op) & (self.C ^ ures)) & 0x80) != 0 { self.P.insert(.v) }
                 self.C = (self.C & 0xFF00) | (ures & 0xFF)
             } else {
                 let res = Int32(self.C) - Int32(op) - Int32(borrow)
                 self.P.remove([.c, .z, .n, .v]); if res >= 0 { self.P.insert(.c) }
                 if (res & 0xFFFF) == 0 { self.P.insert(.z) }; if (res & 0x8000) != 0 { self.P.insert(.n) }
                 let ures = UInt32(bitPattern: res);
                 if (((UInt32(self.C) ^ UInt32(op)) & (UInt32(self.C) ^ ures)) & 0x8000) != 0 { self.P.insert(.v) }
                 self.C = UInt16(ures & 0xFFFF)
             }
        }
        self.cyclesRemaining += 2
    }
    
    func op_cmp(_ m: ()->Void) {
        m()

        let is8 = self.e_mode || self.P.contains(.m)

        let op: UInt16
        if is8 {
            op = UInt16(self.bus.read(self.opAddr))
        } else {
            let lo = UInt16(self.bus.read(self.opAddr))
            let hi = UInt16(self.bus.read(self.opAddr &+ 1))
            op = (hi << 8) | lo
        }

        // 🔥 DEBUG — ADD THIS
        print(String(format:
            "CMP LOOP DEBUG: PC=%04X  A=%04X  ADDR=%06X  LO=%02X HI=%02X  OP=%04X  P=%02X",
            self.PC,
            self.C,
            self.opAddr,
            self.bus.read(self.opAddr),
            self.bus.read(self.opAddr &+ 1),
            op,
            self.P.rawValue
        ))

        let r = is8 ? (self.C & 0x00FF) : self.C
        let val = r &- op

        self.P.remove([.c, .z, .n])

        if r >= op { self.P.insert(.c) }
        if val == 0 { self.P.insert(.z) }

        if is8 {
            if (val & 0x0080) != 0 { self.P.insert(.n) }
        } else {
            if (val & 0x8000) != 0 { self.P.insert(.n) }
        }

        self.cyclesRemaining += 2
    }


    func op_cpx(_ m: ()->Void) {
        m()
        let is8 = self.e_mode || self.P.contains(.x)

        let op: UInt16
        if is8 {
            op = UInt16(self.bus.read(self.opAddr))
        } else {
            let lo = UInt16(self.bus.read(self.opAddr))
            let hi = UInt16(self.bus.read(self.opAddr &+ 1))
            op = (hi << 8) | lo
        }

        let r = is8 ? (self.X & 0x00FF) : self.X
        let val = r &- op

        self.P.remove([.c, .z, .n])
        if r >= op { self.P.insert(.c) }
        if val == 0 { self.P.insert(.z) }
        if is8 {
            if (val & 0x0080) != 0 { self.P.insert(.n) }
        } else {
            if (val & 0x8000) != 0 { self.P.insert(.n) }
        }

        self.cyclesRemaining += 2
    }

    func op_cpy(_ m: ()->Void) {
        m()
        let is8 = self.e_mode || self.P.contains(.x)

        let op: UInt16
        if is8 {
            op = UInt16(self.bus.read(self.opAddr))
        } else {
            let lo = UInt16(self.bus.read(self.opAddr))
            let hi = UInt16(self.bus.read(self.opAddr &+ 1))
            op = (hi << 8) | lo
        }

        let r = is8 ? (self.Y & 0x00FF) : self.Y
        let val = r &- op

        self.P.remove([.c, .z, .n])
        if r >= op { self.P.insert(.c) }
        if val == 0 { self.P.insert(.z) }
        if is8 {
            if (val & 0x0080) != 0 { self.P.insert(.n) }
        } else {
            if (val & 0x8000) != 0 { self.P.insert(.n) }
        }

        self.cyclesRemaining += 2
    }

    func op_and(_ m: ()->Void) { m(); if self.e_mode||self.P.contains(.m) { self.C = (self.C&0xFF00)|UInt16(self.bus.read(self.opAddr) & UInt8(self.C&0xFF)); self.setZN(self.C&0xFF, is8:true) } else { self.C &= self.bus.readWord(self.opAddr); self.setZN(self.C, is8:false) }; self.cyclesRemaining+=2 }
    func op_ora(_ m: ()->Void) { m(); if self.e_mode||self.P.contains(.m) { self.C = (self.C&0xFF00)|UInt16(self.bus.read(self.opAddr) | UInt8(self.C&0xFF)); self.setZN(self.C&0xFF, is8:true) } else { self.C |= self.bus.readWord(self.opAddr); self.setZN(self.C, is8:false) }; self.cyclesRemaining+=2 }
    func op_eor(_ m: ()->Void) { m(); if self.e_mode||self.P.contains(.m) { self.C = (self.C&0xFF00)|UInt16(self.bus.read(self.opAddr) ^ UInt8(self.C&0xFF)); self.setZN(self.C&0xFF, is8:true) } else { self.C ^= self.bus.readWord(self.opAddr); self.setZN(self.C, is8:false) }; self.cyclesRemaining+=2 }
    
    func op_bit(_ m: ()->Void) {
        m(); let is8 = self.e_mode || self.P.contains(.m)
        let op = is8 ? UInt16(self.bus.read(self.opAddr)) : self.bus.readWord(self.opAddr)
        let a = is8 ? (self.C & 0xFF) : self.C

        self.P.remove([.z, .n, .v])
        if (a & op) == 0 { self.P.insert(.z) }
        
        if is8 {
            if (op & 0x80) != 0 { self.P.insert(.n) }
            if (op & 0x40) != 0 { self.P.insert(.v) }
        } else {
            if (op & 0x8000) != 0 { self.P.insert(.n) }
            if (op & 0x4000) != 0 { self.P.insert(.v) }
        }

        self.cyclesRemaining += 2
    }
    
    func op_bit_imm() {
        let is8 = self.e_mode || self.P.contains(.m)
        let val = is8 ? UInt16(self.fetchByte()) : self.fetchWord()
        let a = is8 ? (self.C & 0xFF) : self.C

        self.P.remove([.z, .n, .v])
        if (a & val) == 0 { self.P.insert(.z) }
        if is8 {
            if (val & 0x80) != 0 { self.P.insert(.n) }
            if (val & 0x40) != 0 { self.P.insert(.v) }
        } else {
            if (val & 0x8000) != 0 { self.P.insert(.n) }
            if (val & 0x4000) != 0 { self.P.insert(.v) }
        }

        self.cyclesRemaining = 2
    }

    func op_rep() { let val = self.fetchByte(); self.P.remove(StatusFlags(rawValue: val)); if self.P.contains(.m) { self.C &= 0xFF }; if self.P.contains(.x) { self.X &= 0xFF; self.Y &= 0xFF }; self.cyclesRemaining=3 }
    func op_sep() { let val = self.fetchByte(); self.P.insert(StatusFlags(rawValue: val)); if self.P.contains(.m) { self.C &= 0xFF }; if self.P.contains(.x) { self.X &= 0xFF; self.Y &= 0xFF }; self.cyclesRemaining=3 }
    func op_xba() { let l = self.C & 0xFF; let h = (self.C >> 8) & 0xFF; self.C = (l << 8) | h; self.setZN(h, is8:true); self.cyclesRemaining=3 }
    
    func op_tcd() { self.DP = self.C; self.setZN(self.DP, is8:false); self.cyclesRemaining=2 }
    func op_tcs() { self.SP = self.C; self.cyclesRemaining=2 }
    func op_tsc() { self.C = self.SP; self.setZN(self.C, is8:false); self.cyclesRemaining=2 }
    func op_tdc() { self.C = self.DP; self.setZN(self.C, is8:false); self.cyclesRemaining=2 }
    func op_txa() { let is8 = self.e_mode || self.P.contains(.m); if is8 { self.C = (self.C & 0xFF00) | (self.X & 0xFF); self.setZN(self.C & 0xFF, is8: true) } else { self.C = self.X; self.setZN(self.C, is8: false) }; self.cyclesRemaining = 2 }
    func op_tya() { let is8 = self.e_mode || self.P.contains(.m); if is8 { self.C = (self.C & 0xFF00) | (self.Y & 0xFF); self.setZN(self.C & 0xFF, is8: true) } else { self.C = self.Y; self.setZN(self.C, is8: false) }; self.cyclesRemaining = 2 }
    func op_tax() { let is8 = self.e_mode || self.P.contains(.x); if is8 { self.X = (self.X & 0xFF00) | (self.C & 0xFF); self.setZN(self.X & 0xFF, is8: true) } else { self.X = self.C; self.setZN(self.X, is8: false) }; self.cyclesRemaining = 2 }
    func op_txy() { let is8 = self.e_mode || self.P.contains(.x); if is8 { self.Y = (self.Y & 0xFF00) | (self.X & 0xFF); self.setZN(self.Y & 0xFF, is8: true) } else { self.Y = self.X; self.setZN(self.Y, is8: false) }; self.cyclesRemaining = 2 }
    func op_tyx() { let is8 = self.e_mode || self.P.contains(.x); if is8 { self.X = (self.X & 0xFF00) | (self.Y & 0xFF); self.setZN(self.X & 0xFF, is8: true) } else { self.X = self.Y; self.setZN(self.X, is8: false) }; self.cyclesRemaining = 2 }
    func op_tay() { let is8 = self.e_mode || self.P.contains(.x); if is8 { self.Y = (self.Y & 0xFF00) | (self.C & 0xFF); self.setZN(self.Y & 0xFF, is8: true) } else { self.Y = self.C; self.setZN(self.Y, is8: false) }; self.cyclesRemaining = 2 }
    func op_txs() { self.SP = self.X; self.cyclesRemaining = 2 }
    func op_tsx() { let is8 = self.e_mode || self.P.contains(.x); if is8 { self.X = (self.X & 0xFF00) | (self.SP & 0xFF); self.setZN(self.X & 0xFF, is8: true) } else { self.X = self.SP; self.setZN(self.X, is8: false) }; self.cyclesRemaining = 2 }

    func op_pha() { if self.e_mode || self.P.contains(.m) { self.pushByte(UInt8(self.C & 0xFF)) } else { self.pushWord(self.C) }; self.cyclesRemaining = 3 }
    func op_pla() { if self.e_mode || self.P.contains(.m) { let v = self.popByte(); self.C = (self.C & 0xFF00) | UInt16(v); self.setZN(UInt16(v), is8: true) } else { self.C = self.popWord(); self.setZN(self.C, is8: false) }; self.cyclesRemaining = 4 }
    func op_phx() { if self.e_mode || self.P.contains(.x) { self.pushByte(UInt8(self.X & 0xFF)) } else { self.pushWord(self.X) }; self.cyclesRemaining = 3 }
    func op_plx() { if self.e_mode || self.P.contains(.x) { let v = self.popByte(); self.X = (self.X & 0xFF00) | UInt16(v); self.setZN(UInt16(v), is8: true) } else { self.X = self.popWord(); self.setZN(self.X, is8: false) }; self.cyclesRemaining = 4 }
    func op_phy() { if self.e_mode || self.P.contains(.x) { self.pushByte(UInt8(self.Y & 0xFF)) } else { self.pushWord(self.Y) }; self.cyclesRemaining = 3 }
    func op_ply() { if self.e_mode || self.P.contains(.x) { let v = self.popByte(); self.Y = (self.Y & 0xFF00) | UInt16(v); self.setZN(UInt16(v), is8: true) } else { self.Y = self.popWord(); self.setZN(self.Y, is8: false) }; self.cyclesRemaining = 4 }
    func op_phd() { self.pushWord(self.DP); self.cyclesRemaining=4 }
    func op_pld() { self.DP = self.popWord(); self.setZN(self.DP, is8:false); self.cyclesRemaining=5 }
    func op_phb() { self.pushByte(self.DB); self.cyclesRemaining=3 }
    func op_plb() { self.DB = self.popByte(); self.setZN(UInt16(self.DB), is8:true); self.cyclesRemaining=4 }
    func op_php() { let stackedP = self.P.rawValue | 0x10; self.pushByte(stackedP); self.cyclesRemaining = 3 }
    func op_plp() {
        let raw = self.popByte(); self.P = StatusFlags(rawValue: raw & ~0x10)
        if self.P.contains(.x) { self.X &= 0xFF; self.Y &= 0xFF }
        if self.P.contains(.m) { self.C &= 0xFF }
        self.cyclesRemaining = 4
    }
    func op_phk() { self.pushByte(self.PB); self.cyclesRemaining = 3 }
    func op_pea_imm16() { let value = self.fetchWord(); self.pushWord(value); self.cyclesRemaining = 5 } // Push Effective Absolute Address
    func op_pei(_ m: ()->Void) { m(); self.pushWord(UInt16(self.opAddr & 0xFFFF)); self.cyclesRemaining=6 } // Push Effective Indirect Address

    func op_jmp_abs_ind() {
        self.am_abs_ind()
        self.PC = UInt16(self.opAddr & 0xFFFF)
        self.cyclesRemaining += 1   // extra cycle for jump itself
    }

    func op_jmp_abs_ind_x() {
        // 1) Fetch base address
        let base = self.fetchWord()

        // 2) Apply X index with correct width
        let xVal: UInt16 = (self.e_mode || self.P.contains(.x))
            ? UInt16(self.X & 0x00FF)
            : self.X

        let ptr = base &+ xVal

        // 3) Read indirect target with 6502/65816 wrap bug
        let lo = self.bus.read(UInt32(ptr))
        let hi = self.bus.read(UInt32((ptr & 0xFF00) | UInt16((ptr &+ 1) & 0x00FF)))

        // 4) Set PC only (PB unchanged)
        self.PC = UInt16(hi) << 8 | UInt16(lo)

        // 5) Correct timing
        self.cyclesRemaining += 6
    }

    func op_rti() {
        if self.e_mode {
            let p = self.popByte(); self.P = StatusFlags(rawValue: p & 0xEF)
            let lo = self.popByte(); let hi = self.popByte(); self.PC = (UInt16(hi) << 8) | UInt16(lo)
            self.cyclesRemaining = 6
        } else {
            let p = self.popByte(); self.P = StatusFlags(rawValue: (p & 0xEF) | 0x20)
            let lo = self.popByte(); let hi = self.popByte(); self.PC = (UInt16(hi) << 8) | UInt16(lo)
            self.PB = self.popByte()
            self.cyclesRemaining = 7
        }
    }
    func op_brk() {
        self.PC &+= 1
        self.pushWord(self.PC)
        self.pushByte(self.P.rawValue | 0x10)
        self.P.insert(.i)
        self.PC = self.bus.readWord(0xFFFE) // Use $FFFE/$FFFF for BRK vector
        self.cyclesRemaining = 7
    }
    func op_cop() {
        _ = self.fetchByte() // read operand
        if self.e_mode {
            self.pushWord(self.PC)
            self.pushByte(self.P.rawValue & ~0x10)
            self.P.insert(.i)
            self.PC = self.bus.readWord(0xFFF4)
            self.cyclesRemaining = 7
        } else {
            self.pushByte(self.PB)
            self.pushWord(self.PC)
            self.pushByte(self.P.rawValue & ~0x10)
            self.P.insert(.i)
            self.PB = 0x00
            self.PC = self.bus.readWord(0xFFE4)
            self.cyclesRemaining = 8
        }
    }
    func op_jsr() { self.pushWord(self.PC &- 1); self.am_abs(); self.PC = UInt16(self.opAddr & 0xFFFF); self.cyclesRemaining+=3 }
    func op_jsl() { self.pushByte(self.PB); self.pushWord(self.PC &- 1); self.am_abs_long(); self.PB = UInt8((self.opAddr >> 16) & 0xFF); self.PC = UInt16(self.opAddr & 0xFFFF); self.cyclesRemaining+=4 }
    func op_rts() { self.PC = self.popWord() &+ 1; self.cyclesRemaining = 6 }
    func op_rtl() { let lo = self.popByte(); let hi = self.popByte(); self.PC = (UInt16(hi) << 8) | UInt16(lo); self.PC &+= 1; self.PB = self.popByte(); self.cyclesRemaining = 6 }

    func op_wdm() { _ = self.fetchByte(); self.cyclesRemaining=2 }
    func op_tsb(_ m: ()->Void) { m(); let is8 = self.e_mode || self.P.contains(.m); if is8 { let addr = self.opAddr; let val = self.bus.read(addr); if (val & UInt8(self.C&0xFF)) == 0 { self.P.insert(.z) } else { self.P.remove(.z) }; self.bus.write(addr, data: val | UInt8(self.C&0xFF)) } else { let addr = self.opAddr; let val = self.bus.readWord(addr); if (val & self.C) == 0 { self.P.insert(.z) } else { self.P.remove(.z) }; self.bus.writeWord(addr, data: val | self.C) }; self.cyclesRemaining+=4 }
    func op_trb(_ m: ()->Void) { m(); let is8 = self.e_mode || self.P.contains(.m); if is8 { let addr = self.opAddr; let val = self.bus.read(addr); if (val & UInt8(self.C&0xFF)) == 0 { self.P.insert(.z) } else { self.P.remove(.z) }; self.bus.write(addr, data: val & ~UInt8(self.C&0xFF)) } else { let addr = self.opAddr; let val = self.bus.readWord(addr); if (val & self.C) == 0 { self.P.insert(.z) } else { self.P.remove(.z) }; self.bus.writeWord(addr, data: val & ~self.C) }; self.cyclesRemaining+=4 }
    func op_mvn() { let dst=self.fetchByte(); let src=self.fetchByte(); self.DB=dst; self._block_move(src:src, dst:dst, inc:1) }
    func op_mvp() { let dst=self.fetchByte(); let src=self.fetchByte(); self.DB=dst; self._block_move(src:src, dst:dst, inc:-1) }
    
    func _block_move(src:UInt8, dst:UInt8, inc:Int) {
        let count = self.C &+ 1 // Use self.C
        var sOff = Int(self.X) // Use self.X
        var dOff = Int(self.Y) // Use self.Y
        
        for _ in 0..<Int(count) { // Cast count to Int for loop range
            self.bus.write((UInt32(dst)<<16)|UInt32(dOff&0xFFFF), data: self.bus.read((UInt32(src)<<16)|UInt32(sOff&0xFFFF)))
            sOff+=inc;
            dOff+=inc
        }
        
        self.X = UInt16(sOff&0xFFFF);
        self.Y = UInt16(dOff&0xFFFF);
        self.C = 0xFFFF; // Use self.C
        self.cyclesRemaining=Int(count)*7
    }
    
    
    private func setupOpcodeTable() {
        for i in 0..<256 { self.lookup[i] = {
            print("Missing Opcode: \(String(format: "%02X", i)) at PC: \(String(format: "%04X", self.PC &- 1))")
            self.cyclesRemaining = 2
        } }

        self.lookup[0xEA] = { self.cyclesRemaining = 2 } // NOP
        self.lookup[0xCB] = { self.waitingForInterrupt = true; self.cyclesRemaining = 2 } // STP (Stop)
        self.lookup[0x42] = { self.op_wdm() } // WDM (Reserved)
        self.lookup[0x00] = { self.op_brk() } // BRK (Break)
        self.lookup[0x02] = { self.op_cop() } // COP (Co-processor)
        self.lookup[0xEB] = { self.op_xba() } // XBA (Exchange High/Low)

        self.lookup[0x18] = { self.P.remove(.c); self.cyclesRemaining = 2 } // CLC
        self.lookup[0x38] = { self.P.insert(.c); self.cyclesRemaining = 2 } // SEC
        self.lookup[0x58] = { self.P.remove(.i); self.cyclesRemaining = 2 } // CLI
        self.lookup[0x78] = { self.P.insert(.i); self.cyclesRemaining = 2 } // SEI
        self.lookup[0xD8] = { self.P.remove(.d); self.cyclesRemaining = 2 } // CLD
        self.lookup[0xF8] = { self.P.insert(.d); self.cyclesRemaining = 2 } // SED
        self.lookup[0xFB] = { let c=self.P.contains(.c); let e=self.e_mode; self.e_mode=c; if e {self.P.insert(.c)} else {self.P.remove(.c)}; if !self.e_mode {self.P.insert([.m,.x])}; self.cyclesRemaining=2 } // XCE
        self.lookup[0xC2] = { self.op_rep() } // REP
        self.lookup[0xE2] = { self.op_sep() } // SEP

        // MARK: - LDA (Load Accumulator)
        self.lookup[0xA9] = { self.op_lda(self.am_imm_m) }    // #const
        self.lookup[0xA5] = { self.op_lda(self.am_dp) }      // dp
        self.lookup[0xA7] = { self.op_lda(self.am_ind_long_dp) } // [dp]
        self.lookup[0xAD] = { self.op_lda(self.am_abs) }     // addr
        self.lookup[0xAF] = { self.op_lda(self.am_abs_long) } // long
        self.lookup[0xB1] = { self.op_lda(self.am_dp_ind_y) } // (dp),y
        self.lookup[0xB2] = { self.op_lda(self.am_ind) }      // (dp)
        self.lookup[0xB3] = { self.op_lda(self.am_sr_iy) }    // ($s,x),y
        self.lookup[0xB7] = { self.op_lda(self.am_ind_long_dp_y) } // [dp],y
        self.lookup[0xBD] = { self.op_lda(self.am_abs_x) }    // addr,x
        self.lookup[0xBF] = { self.op_lda(self.am_abs_long_x) } // long,x
        self.lookup[0xB9] = { self.op_lda(self.am_abs_y) }    // addr,y
        self.lookup[0xB5] = { self.op_lda(self.am_dp_x) } // LDA dp,x (Added previously)
        self.lookup[0xA1] = { self.op_lda(self.am_dp_x_ind) } // LDA (dp,x)
        self.lookup[0xA3] = { self.op_lda(self.am_sr) } // LDA $s,x

        // MARK: - STA (Store Accumulator)
        self.lookup[0x85] = { self.op_sta(self.am_dp) }      // dp
        self.lookup[0x87] = { self.op_sta(self.am_ind_long_dp) } // [dp]
        self.lookup[0x8D] = { self.op_sta(self.am_abs) }     // addr
        self.lookup[0x8F] = { self.op_sta(self.am_abs_long) } // long
        self.lookup[0x91] = { self.op_sta(self.am_dp_ind_y) } // (dp),y
        self.lookup[0x92] = { self.op_sta(self.am_ind) }      // (dp)
        self.lookup[0x93] = { self.op_sta(self.am_sr_iy) }    // ($s,x),y
        self.lookup[0x97] = { self.op_sta(self.am_ind_long_dp_y) } // [dp],y
        self.lookup[0x99] = { self.op_sta(self.am_abs_y) }    // addr,y
        self.lookup[0x9D] = { self.op_sta(self.am_abs_x) }    // addr,x
        self.lookup[0x9F] = { self.op_sta(self.am_abs_long_x) } // long,x
        self.lookup[0x81] = { self.op_sta(self.am_dp_x_ind) } // (dp,x)
        self.lookup[0x83] = { self.op_sta(self.am_sr) }       // $s,x
        self.lookup[0x95] = { self.op_sta(self.am_dp_x) } // STA dp,x (Added previously)

        // MARK: - LDX (Load X Register)
        self.lookup[0xA2] = { self.op_ldx(self.am_imm_x) }
        self.lookup[0xA6] = { self.op_ldx(self.am_dp) }       // dp
        self.lookup[0xAE] = { self.op_ldx(self.am_abs) }
        self.lookup[0xBE] = { self.op_ldx(self.am_abs_y) }    // addr,y
        self.lookup[0xB6] = { self.op_ldx(self.am_dp_y) }     // LDX dp,y (NEW #17)
        
        // MARK: - STX (Store X Register)
        self.lookup[0x86] = { self.op_stx(self.am_dp) }       // dp
        self.lookup[0x8E] = { self.op_stx(self.am_abs) }
        self.lookup[0x96] = { self.op_stx(self.am_dp_y) }     // dp,y
        self.lookup[0x9E] = { self.op_stx(self.am_abs_y) }    // STX abs,y (NEW #18)
        
        // MARK: - LDY (Load Y Register)
        self.lookup[0xA0] = { self.op_ldy(self.am_imm_x) }
        self.lookup[0xA4] = { self.op_ldy(self.am_dp) }       // dp
        self.lookup[0xAC] = { self.op_ldy(self.am_abs) }
        self.lookup[0xBC] = { self.op_ldy(self.am_abs_x) }    // LDY abs,x (NEW #15 - was addr,x)
        self.lookup[0xB4] = { self.op_ldy(self.am_dp_x) }     // LDY dp,x (NEW #16)
        
        // MARK: - STY (Store Y Register)
        self.lookup[0x84] = { self.op_sty(self.am_dp) }       // dp
        self.lookup[0x8C] = { self.op_sty(self.am_abs) }
        self.lookup[0x94] = { self.op_sty(self.am_dp_x) }     // dp,x

        // MARK: - STZ (Store Zero)
        self.lookup[0x64] = { self.op_stz(self.am_dp) }
        self.lookup[0x74] = { self.op_stz(self.am_dp_x) }
        self.lookup[0x9C] = { self.op_stz(self.am_abs) }
        self.lookup[0x9E] = { self.op_stz(self.am_abs_x) } // addr,x

        // MARK: - AND (Logical AND)
        self.lookup[0x29] = { self.op_and(self.am_imm_m) }
        self.lookup[0x25] = { self.op_and(self.am_dp) }
        self.lookup[0x2D] = { self.op_and(self.am_abs) }
        self.lookup[0x3F] = { self.op_and(self.am_abs_long_x) } // long,x
        self.lookup[0x21] = { self.op_and(self.am_dp_x_ind) }
        self.lookup[0x23] = { self.op_and(self.am_sr) }
        self.lookup[0x33] = { self.op_and(self.am_sr_iy) }
        self.lookup[0x2F] = { self.op_and(self.am_abs_long) }
        self.lookup[0x37] = { self.op_and(self.am_ind_long_dp_y) } // AND [dp],y
        self.lookup[0x39] = { self.op_and(self.am_abs_y) } // AND addr,y (NEW #3)
        self.lookup[0x3D] = { self.op_and(self.am_abs_x) } // AND addr,x (NEW #2)
        self.lookup[0x35] = { self.op_and(self.am_dp_x) } // AND dp,x (NEW #1)

        // MARK: - ORA (Logical OR)
        self.lookup[0x09] = { self.op_ora(self.am_imm_m) }
        self.lookup[0x05] = { self.op_ora(self.am_dp) }
        self.lookup[0x0D] = { self.op_ora(self.am_abs) }
        self.lookup[0x1F] = { self.op_ora(self.am_abs_long_x) }
        self.lookup[0x01] = { self.op_ora(self.am_dp_x_ind) }
        self.lookup[0x03] = { self.op_ora(self.am_sr) }
        self.lookup[0x13] = { self.op_ora(self.am_sr_iy) }
        self.lookup[0x12] = { self.op_ora(self.am_ind) }
        self.lookup[0x07] = { self.op_ora(self.am_ind_long_dp) }
        self.lookup[0x15] = { self.op_ora(self.am_dp_x) }
        self.lookup[0x0F] = { self.op_ora(self.am_abs_long) } // ORA long (Corrected existing mapping)
        self.lookup[0x17] = { self.op_ora(self.am_ind_long_dp_y) } // ORA [dp],y
        self.lookup[0x19] = { self.op_ora(self.am_abs_y) } // ORA addr,y

        // MARK: - EOR (Exclusive OR)
        self.lookup[0x49] = { self.op_eor(self.am_imm_m) }
        self.lookup[0x45] = { self.op_eor(self.am_dp) }
        self.lookup[0x4D] = { self.op_eor(self.am_abs) }
        self.lookup[0x5D] = { self.op_eor(self.am_abs_x) }
        self.lookup[0x59] = { self.op_eor(self.am_abs_y) }
        self.lookup[0x41] = { self.op_eor(self.am_dp_x_ind) }
        self.lookup[0x55] = { self.op_eor(self.am_dp_x) }
        self.lookup[0x43] = { self.op_eor(self.am_sr) }
        self.lookup[0x53] = { self.op_eor(self.am_sr_iy) }
        self.lookup[0x52] = { self.op_eor(self.am_ind) } // EOR (dp)
        self.lookup[0x57] = { self.op_eor(self.am_ind_long_dp_y) } // EOR [dp],y
        self.lookup[0x5F] = { self.op_eor(self.am_abs_long) } // EOR long (NEW #11)
        self.lookup[0x4F] = { self.op_eor(self.am_abs_long) } // EOR long (0x4F is EOR long)

        // MARK: - BIT (Test Bits)
        self.lookup[0x89] = { self.op_bit_imm() }
        self.lookup[0x24] = { self.op_bit(self.am_dp) }       // dp
        self.lookup[0x2C] = { self.op_bit(self.am_abs) }      // addr
        self.lookup[0x34] = { self.op_bit(self.am_dp_x) }     // dp,x
        self.lookup[0x3C] = { self.op_bit(self.am_abs_x) }    // addr,x
        self.lookup[0x2F] = { self.op_bit(self.am_abs_long) } // BIT long

        // MARK: - ADC (Add with Carry)
        self.lookup[0x69] = { self.op_adc(self.am_imm_m) }
        self.lookup[0x6D] = { self.op_adc(self.am_abs) }
        self.lookup[0x7F] = { self.op_adc(self.am_abs_long_x) }
        self.lookup[0x63] = { self.op_adc(self.am_sr) }
        self.lookup[0x73] = { self.op_adc(self.am_sr_iy) }
        self.lookup[0x72] = { self.op_adc(self.am_ind) } // ADC (dp)
        self.lookup[0x77] = { self.op_adc(self.am_ind_long_dp_y) } // ADC [dp],y
        self.lookup[0x75] = { self.op_adc(self.am_dp_x) } // ADC dp,x (NEW #4)
        self.lookup[0x65] = { self.op_adc(self.am_dp) } // ADC dp (NEW #5 - was missing)
        self.lookup[0x7D] = { self.op_adc(self.am_abs_x) } // ADC abs,x (NEW #6)
        self.lookup[0x79] = { self.op_adc(self.am_abs_y) } // ADC abs,y (NEW #7)

        // MARK: - SBC (Subtract with Borrow)
        self.lookup[0xE9] = { self.op_sbc(self.am_imm_m) }
        self.lookup[0xED] = { self.op_sbc(self.am_abs) }
        self.lookup[0xFF] = { self.op_sbc(self.am_abs_long_x) }
        self.lookup[0xE3] = { self.op_sbc(self.am_sr) }
        self.lookup[0xF3] = { self.op_sbc(self.am_sr_iy) }
        self.lookup[0xF2] = { self.op_sbc(self.am_ind) }
        self.lookup[0xF5] = { self.op_sbc(self.am_dp_x) } // SBC dp,x
        self.lookup[0xF9] = { self.op_sbc(self.am_abs_y) } // SBC addr,y
        self.lookup[0xE5] = { self.op_sbc(self.am_dp) } // SBC dp (NEW #8)
        self.lookup[0xFD] = { self.op_sbc(self.am_abs_x) } // SBC abs,x (NEW #9)

        // MARK: - CMP (Compare Accumulator)
        self.lookup[0xC9] = { self.op_cmp(self.am_imm_m) }
        self.lookup[0xCD] = { self.op_cmp(self.am_abs) }
        self.lookup[0xDF] = { self.op_cmp(self.am_abs_long_x) }
        self.lookup[0xC3] = { self.op_cmp(self.am_sr) }
        self.lookup[0xD3] = { self.op_cmp(self.am_sr_iy) }
        self.lookup[0xC5] = { self.op_cmp(self.am_dp) }        // CMP dp
        self.lookup[0xD5] = { self.op_cmp(self.am_dp_x) }      // CMP dp,x
        self.lookup[0xD9] = { self.op_cmp(self.am_abs_y) }     // CMP abs,y
        self.lookup[0xCF] = { self.op_cmp(self.am_abs_long) }  // CMP long

        // MARK: - CPX (Compare X)
        self.lookup[0xE0] = { self.op_cpx(self.am_imm_x) }
        self.lookup[0xE4] = { self.op_cpx(self.am_dp) }
        self.lookup[0xEC] = { self.op_cpx(self.am_abs) }

        // MARK: - CPY (Compare Y)
        self.lookup[0xC0] = { self.op_cpy(self.am_imm_x) }
        self.lookup[0xC4] = { self.op_cpy(self.am_dp) }
        self.lookup[0xCC] = { self.op_cpy(self.am_abs) }


        // MARK: - ASL (Arithmetic Shift Left)
        self.lookup[0x0A] = { self.op_asl(self.am_acc, acc: true) }
        self.lookup[0x06] = { self.op_asl(self.am_dp, acc: false) }
        self.lookup[0x0E] = { self.op_asl(self.am_abs, acc: false) }
        self.lookup[0x16] = { self.op_asl(self.am_dp_x, acc: false) }
        self.lookup[0x1E] = { self.op_asl(self.am_abs_x, acc: false) }
        
        // MARK: - LSR (Logical Shift Right)
        self.lookup[0x4A] = { self.op_lsr(self.am_acc, acc: true) }
        self.lookup[0x46] = { self.op_lsr(self.am_dp, acc: false) }
        self.lookup[0x4E] = { self.op_lsr(self.am_abs, acc: false) }
        self.lookup[0x56] = { self.op_lsr(self.am_dp_x, acc: false) }
        self.lookup[0x5E] = { self.op_lsr(self.am_abs_x, acc: false) }

        // MARK: - ROL (Rotate Left)
        self.lookup[0x2A] = { self.op_rol(self.am_acc, acc: true) }
        self.lookup[0x26] = { self.op_rol(self.am_dp, acc: false) }
        self.lookup[0x2E] = { self.op_rol(self.am_abs, acc: false) }
        self.lookup[0x36] = { self.op_rol(self.am_dp_x, acc: false) }
        self.lookup[0x3E] = { self.op_rol(self.am_abs_x, acc: false) }

        // MARK: - ROR (Rotate Right)
        self.lookup[0x6A] = { self.op_ror(self.am_acc, acc: true) }
        self.lookup[0x66] = { self.op_ror(self.am_dp, acc: false) }
        self.lookup[0x6E] = { self.op_ror(self.am_abs, acc: false) }
        self.lookup[0x76] = { self.op_ror(self.am_dp_x, acc: false) } // DP,X
        self.lookup[0x7E] = { self.op_ror(self.am_abs_x, acc: false) }

        // MARK: - INC/DEC (Increment/Decrement Memory)
        self.lookup[0xE6] = { self.op_inc_dec(self.am_dp, inc: true) } // INC dp
        self.lookup[0xEE] = { self.op_inc_dec(self.am_abs, inc: true) } // INC addr
        self.lookup[0xD6] = { self.op_inc_dec(self.am_dp_x, inc: false) } // DEC dp,x
        self.lookup[0xD2] = { self.op_inc_dec(self.am_dp, inc: false) } // DEC dp
        self.lookup[0xDE] = { self.op_inc_dec(self.am_abs_x, inc: false) } // DEC addr,x
        self.lookup[0xCE] = { self.op_inc_dec(self.am_abs, inc: false) } // DEC addr
        self.lookup[0xC6] = { self.op_inc_dec(self.am_dp, inc: false) } // DEC dp
        self.lookup[0xE7] = { self.op_inc_dec(self.am_ind_long_dp, inc: true) } // INC [dp]
        self.lookup[0xFE] = { self.op_inc_dec(self.am_abs_x, inc: true) } // INC abs,x (NEW #14)

        // MARK: - INC/DEC/Transfer Registers
        self.lookup[0x1A] = { self.op_inc_acc(); } // INC A
        self.lookup[0x3A] = { self.op_dec_acc(); } // DEC A
        self.lookup[0xE8] = { self.op_inc_dec_reg(reg: &self.X, is8: self.e_mode || self.P.contains(.x)); self.cyclesRemaining = 2 } // INX
        self.lookup[0xC8] = { self.op_inc_dec_reg(reg: &self.Y, is8: self.e_mode || self.P.contains(.x)); self.cyclesRemaining = 2 } // INY
        self.lookup[0xCA] = { self.op_inc_dec_reg(reg: &self.X, is8: self.e_mode || self.P.contains(.x), inc: false); self.cyclesRemaining = 2 } // DEX
        self.lookup[0x88] = { self.op_inc_dec_reg(reg: &self.Y, is8: self.e_mode || self.P.contains(.x), inc: false); self.cyclesRemaining = 2 } // DEY

        self.lookup[0x5B] = { self.op_tcd() } // TCD
        self.lookup[0x1B] = { self.op_tcs() } // TCS
        self.lookup[0x7B] = { self.op_tdc() } // TDC
        self.lookup[0x3B] = { self.op_tsc() } // TSC
        self.lookup[0x8A] = { self.op_txa() } // TXA
        self.lookup[0x98] = { self.op_tya() } // TYA
        self.lookup[0xAA] = { self.op_tax() } // TAX
        self.lookup[0xA8] = { self.op_tay() } // TAY
        self.lookup[0x9A] = { self.op_txs() } // TXS
        self.lookup[0xBA] = { self.op_tsx() } // TSX
        self.lookup[0xBB] = { self.op_txy() } // TXY (Note: TXY is 0xBB, but was used for TAY in file, corrected to TXY logic)
        self.lookup[0x5A] = { self.op_tyx() } // TYX (Note: PHX is 0xDA, using 0x5A for TYX)

        // MARK: - Stack Operations
        self.lookup[0x48] = { self.op_pha() } // PHA
        self.lookup[0x68] = { self.op_pla() } // PLA
        self.lookup[0xDA] = { self.op_phx() } // PHX
        self.lookup[0xFA] = { self.op_plx() } // PLX
        self.lookup[0x5A] = { self.op_phy() } // PHY (Corrected from earlier TYX, using 0x5A for PHY which is standard)
        self.lookup[0x7A] = { self.op_ply() } // PLY
        self.lookup[0x0B] = { self.op_phd() } // PHD
        self.lookup[0x2B] = { self.op_pld() } // PLD
        self.lookup[0x8B] = { self.op_phb() } // PHB
        self.lookup[0xAB] = { self.op_plb() } // PLB
        self.lookup[0x08] = { self.op_php() } // PHP
        self.lookup[0x28] = { self.op_plp() } // PLP
        self.lookup[0x4B] = { self.op_phk() } // PHK
        self.lookup[0x32] = { self.op_pea_imm16() } // PEA #const
        self.lookup[0xF4] = { self.op_pea_imm16() } // PEA #const (Long addressing form, same effect here)
        self.lookup[0xD4] = { self.op_pei(self.am_dp) } // PEI
        self.lookup[0x62] = { self.op_pea_imm16() } // PER (Opcode for PER)

        // MARK: - Jumps and Subroutines
        self.lookup[0x4C] = { self.am_abs(); self.PC = UInt16(self.opAddr & 0xFFFF); self.cyclesRemaining += 3 } // JMP addr
        self.lookup[0x5C] = { self.am_abs_long(); self.PB = UInt8((self.opAddr >> 16) & 0xFF); self.PC = UInt16(self.opAddr & 0xFFFF); self.cyclesRemaining += 4 } // JML long
        self.lookup[0x6C] = { self.op_jmp_abs_ind() } // JMP (addr)
        self.lookup[0x7C] = { self.op_jmp_abs_ind_x() } // JMP (addr,x)
        self.lookup[0xDC] = { self.am_ind_long(); self.PB = UInt8((self.opAddr >> 16) & 0xFF); self.PC = UInt16(self.opAddr & 0xFFFF); self.cyclesRemaining += 6 } // JML [addr]
        self.lookup[0x20] = { self.op_jsr() } // JSR addr
        self.lookup[0x22] = { self.op_jsl() } // JSL long
        self.lookup[0x60] = { self.op_rts() } // RTS
        self.lookup[0x6B] = { self.op_rtl() } // RTL
        self.lookup[0x40] = { self.op_rti() } // RTI
        self.lookup[0x82] = { self.branchLong(self.am_abs_long) } // BRL (Branch Long)
        self.lookup[0xFC] = { self.am_abs_ind_x(); self.pushWord(self.PC &- 1); self.PC = UInt16(self.opAddr & 0xFFFF); self.cyclesRemaining += 4 } // JSR (addr,x)

        // MARK: - Branches
        self.lookup[0x80] = { self.branch(true) } // BRA
        self.lookup[0x90] = { self.branch(!self.P.contains(.c)) } // BCC
        self.lookup[0xB0] = { self.branch(self.P.contains(.c)) } // BCS
        self.lookup[0xD0] = { self.branch(!self.P.contains(.z)) } // BNE
        self.lookup[0xF0] = { self.branch(self.P.contains(.z)) } // BEQ
        self.lookup[0x10] = { self.branch(!self.P.contains(.n)) } // BPL
        self.lookup[0x30] = { self.branch(self.P.contains(.n)) } // BMI
        self.lookup[0x50] = { self.branch(!self.P.contains(.v)) } // BVC
        self.lookup[0x70] = { self.branch(self.P.contains(.v)) } // BVS

        // MARK: - TSB/TRB (Test and Set/Reset Bit)
        self.lookup[0x04] = { self.op_tsb(self.am_dp) }
        self.lookup[0x0C] = { self.op_tsb(self.am_abs) }
        self.lookup[0x14] = { self.op_trb(self.am_dp) }
        self.lookup[0x1C] = { self.op_tsb(self.am_abs_x) } // TSB abs,x (NEW #19)
        self.lookup[0x14] = { self.op_trb(self.am_dp_x) } // TRB dp,x (NEW #20)

        // MARK: - Block Move
        self.lookup[0x54] = { self.op_mvn() }
        self.lookup[0x44] = { self.op_mvp() }
    }
}
