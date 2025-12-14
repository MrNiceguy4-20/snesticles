import Foundation

final class CPU {
    unowned let bus: Bus
    
    var A: UInt16 = 0
    var X: UInt16 = 0
    var Y: UInt16 = 0
    var S: UInt16 = 0x01FF
    var D: UInt16 = 0
    var DB: UInt8 = 0
    var PB: UInt8 = 0
    var PC: UInt16 = 0
    
    var e: Bool = true
    var stopped: Bool = false
    var waiting: Bool = false
    
    struct Flags: OptionSet {
        let rawValue: UInt8
        static let c = Flags(rawValue: 1 << 0)
        static let z = Flags(rawValue: 1 << 1)
        static let i = Flags(rawValue: 1 << 2)
        static let d = Flags(rawValue: 1 << 3)
        static let x = Flags(rawValue: 1 << 4)
        static let m = Flags(rawValue: 1 << 5)
        static let v = Flags(rawValue: 1 << 6)
        static let n = Flags(rawValue: 1 << 7)
    }
    
    var P: Flags = [.m, .x, .i]
    
    private var cycles: Int = 0
    private var addr: UInt32 = 0
    
    private var opcodeTable: [() -> Void] = []
    
    init(bus: Bus) {
        self.bus = bus
        self.opcodeTable = Array(repeating: { self.illegalOpcode() }, count: 256)
        setupOpcodeTable()
    }
    
    func save(to serializer: Serializer) {
        serializer.write(A)
        serializer.write(X)
        serializer.write(Y)
        serializer.write(S)
        serializer.write(D)
        serializer.write(DB)
        serializer.write(PB)
        serializer.write(PC)
        serializer.write(e)
        serializer.write(stopped)
        serializer.write(waiting)
        serializer.write(P.rawValue)
        serializer.write(UInt32(cycles))
    }
    
    func load(from serializer: Serializer) {
        A = serializer.readUInt16()
        X = serializer.readUInt16()
        Y = serializer.readUInt16()
        S = serializer.readUInt16()
        D = serializer.readUInt16()
        DB = serializer.readUInt8()
        PB = serializer.readUInt8()
        PC = serializer.readUInt16()
        e = serializer.readBool()
        stopped = serializer.readBool()
        waiting = serializer.readBool()
        P = Flags(rawValue: serializer.readUInt8())
        cycles = Int(serializer.readUInt32())
        
        if P.contains(.m) { A &= 0xFF }
        if P.contains(.x) { X &= 0xFF; Y &= 0xFF }
    }
    
    func reset() {
        e = true
        stopped = false
        waiting = false
        P = [.m, .x, .i]
        S = 0x01FF
        D = 0
        DB = 0
        PB = 0
        A = 0
        X = 0
        Y = 0
        
        let lo = UInt16(bus.read(0xFFFC))
        let hi = UInt16(bus.read(0xFFFD))
        PC = (hi << 8) | lo
        
        if PC == 0 {
            PC = 0x8000
        }
        cycles = 0
    }
    
    func nmi() {
        if stopped { return }
        pushPB()
        push(PC)
        pushStatus()
        P.insert(.i)
        PB = 0
        if e {
            PC = bus.readWord(0xFFFA)
            cycles = 8
        } else {
            PC = bus.readWord(0xFFEA)
            cycles = 8
        }
        waiting = false
    }
    
    func irq() {
        guard !P.contains(.i), !stopped else { return }
        pushPB()
        push(PC)
        pushStatus()
        P.insert(.i)
        PB = 0
        if e {
            PC = bus.readWord(0xFFFE)
            cycles = 7
        } else {
            PC = bus.readWord(0xFFEE)
            cycles = 7
        }
        waiting = false
    }
    
    func clock() -> Int {
        guard !stopped else { return 6 }
        if waiting {
            cycles = max(cycles - 1, 0)
            return cycles > 0 ? 1 : 0
        }
        if cycles > 0 {
            cycles -= 1
            return 1
        }
        
        let opcode = fetchByte()
        opcodeTable[Int(opcode)]()
        return cycles
    }
    
    @inline(__always)
    private func fetchByte() -> UInt8 {
        defer { PC &+= 1 }
        return bus.read((UInt32(PB) << 16) | UInt32(PC))
    }
    
    @inline(__always)
    private func fetchWord() -> UInt16 {
        let lo = UInt16(fetchByte())
        let hi = UInt16(fetchByte())
        return (hi << 8) | lo
    }
    
    @inline(__always)
    private func readByte(_ address: UInt32) -> UInt8 {
        bus.read(address)
    }
    
    @inline(__always)
    private func readWord(_ address: UInt32) -> UInt16 {
        let lo = UInt16(readByte(address))
        let hi = UInt16(readByte(address &+ 1))
        return (hi << 8) | lo
    }
    
    @inline(__always) private func writeByte(_ address: UInt32, _ value: UInt8) {
            bus.write(address, value)
    }
    
    @inline(__always)
    private func writeWord(_ address: UInt32, _ value: UInt16) {
        writeByte(address, UInt8(value & 0xFF))
        writeByte(address &+ 1, UInt8(value >> 8))
    }
    
    private func pushByte(_ value: UInt8) {
        writeByte(UInt32(S), value)
        S &-= 1
        if e && (S & 0xFF00) == 0 { S |= 0x0100 }
    }
    
    private func pushWord(_ value: UInt16) {
        pushByte(UInt8(value >> 8))
        pushByte(UInt8(value & 0xFF))
    }
    
    private func push(_ value: UInt16) {
        pushWord(value)
    }
    
    private func pushPB() {
        if !e { pushByte(PB) }
    }
    
    private func pushStatus() {
        var flags = P.rawValue
        if e {
            flags |= 0x30
            flags &= ~0x10
        }
        pushByte(flags)
    }
    
    private func popByte() -> UInt8 {
        if e && (S & 0xFF00) == 0x0100 { S &= 0x00FF }
        S &+= 1
        return readByte(UInt32(S))
    }
    
    private func popWord() -> UInt16 {
        let lo = UInt16(popByte())
        let hi = UInt16(popByte())
        return (hi << 8) | lo
    }
    
    private func popPB() -> UInt8 {
        if !e { return popByte() }
        return 0
    }
    
    private var acc8: Bool { e || P.contains(.m) }
    private var idx8: Bool { e || P.contains(.x) }
    
    private func setZN(_ value: UInt16, _ is8bit: Bool) {
        P.remove([.n, .z])
        let masked = is8bit ? value & 0xFF : value
        if masked == 0 { P.insert(.z) }
        if (masked & (is8bit ? 0x80 : 0x8000)) != 0 { P.insert(.n) }
    }
    
    private func adjustRegisters() {
        if P.contains(.m) { A &= 0xFF }
        if P.contains(.x) { X &= 0xFF; Y &= 0xFF }
    }
    
    private func imm(_ is8bit: Bool) {
        addr = (UInt32(PB) << 16) | UInt32(PC)
        PC &+= is8bit ? 1 : 2
    }
    
    private func abs() {
        let offset = fetchWord()
        addr = (UInt32(DB) << 16) | UInt32(offset)
    }
    
    private func absIdx(_ index: UInt16) -> Bool {
        let base = fetchWord()
        let effective = base &+ index
        addr = (UInt32(DB) << 16) | UInt32(effective)
        return !idx8 && ((base ^ effective) & 0xFF00) != 0
    }
    
    private func longAddr() {
        let lo = UInt16(fetchByte())
        let mid = UInt16(fetchByte())
        let hi = UInt16(fetchByte())
        addr = (UInt32(hi) << 16) | (UInt32(mid) << 8) | UInt32(lo)
    }
    
    private func dp(_ offset: UInt16) -> UInt32 {
        return UInt32(D &+ offset)
    }
    
    private func dpIdx(_ offset: UInt16, _ index: UInt16) -> UInt32 {
        return dp(offset) &+ UInt32(index)
    }
    
    private func indirect(_ zpAddr: UInt16) -> UInt32 {
        let ptr = D &+ zpAddr
        let lo = readByte(UInt32(ptr))
        let hi = readByte(UInt32(ptr &+ 1))
        return (UInt32(DB) << 16) | UInt32((UInt16(hi) << 8) | UInt16(lo))
    }
    
    private func indirectLong(_ zpAddr: UInt16) -> UInt32 {
        let ptr = D &+ zpAddr
        let lo = readByte(UInt32(ptr))
        let mid = readByte(UInt32(ptr &+ 1))
        let hi = readByte(UInt32(ptr &+ 2))
        return (UInt32(hi) << 16) | (UInt32(mid) << 8) | UInt32(lo)
    }
    
    private func stackRel(_ offset: UInt8) {
        addr = UInt32(S &+ UInt16(offset))
    }
    
    private func lda() {
        let value = acc8 ? UInt16(readByte(addr)) : readWord(addr)
        A = value
        setZN(value, acc8)
    }
    
    private func sta() {
        if acc8 {
            writeByte(addr, UInt8(A))
        } else {
            writeWord(addr, A)
        }
    }
    
    private func ldx() {
        let value = idx8 ? UInt16(readByte(addr)) : readWord(addr)
        X = value
        setZN(value, idx8)
    }
    
    private func stx() {
        if idx8 {
            writeByte(addr, UInt8(X))
        } else {
            writeWord(addr, X)
        }
    }
    
    private func ldy() {
        let value = idx8 ? UInt16(readByte(addr)) : readWord(addr)
        Y = value
        setZN(value, idx8)
    }
    
    private func sty() {
        if idx8 {
            writeByte(addr, UInt8(Y))
        } else {
            writeWord(addr, Y)
        }
    }
    
    private func adc(_ operand: UInt16) {
            let is8 = acc8
            let carryIn: UInt16 = P.contains(.c) ? 1 : 0
            
            if P.contains(.d) && is8 {
                let aLow = A & 0x0F
                let oLow = operand & 0x0F
                var sumLow = aLow + oLow + carryIn
                if sumLow > 9 { sumLow += 6 }
                
                let aHigh = (A >> 4) & 0x0F
                let oHigh = (operand >> 4) & 0x0F
                var sumHigh = aHigh + oHigh + (sumLow > 9 ? 1 : 0)
                
                if sumHigh > 9 {
                    sumHigh += 6
                    P.insert(.c)
                } else {
                    P.remove(.c)
                }
                
                let result = UInt16(((sumHigh & 0x0F) << 4) | (sumLow & 0x0F))
                P.remove(.v)
                if ~((A ^ operand) & (A ^ result) & 0x80) != 0 { P.insert(.v) }
                A = (A & 0xFF00) | result
                setZN(result, true)
            } else {
                if !is8 { P.remove(.d) }
                
                let op32 = UInt32(operand)
                let a32 = UInt32(A)
                let c32 = UInt32(carryIn)
                
                let sum = a32 + op32 + c32
                
                P.remove([.c, .v])
                if is8 {
                    if sum > 0xFF { P.insert(.c) }
                    let result = UInt16(sum & 0xFF)
                    if (~((a32 ^ op32) & (a32 ^ sum)) & 0x80) != 0 { P.insert(.v) }
                    A = (A & 0xFF00) | result
                    setZN(result, true)
                } else {
                    if sum > 0xFFFF { P.insert(.c) }
                    let result = UInt16(sum & 0xFFFF)
                    if (~((a32 ^ op32) & (a32 ^ sum)) & 0x8000) != 0 { P.insert(.v) }
                    A = result
                    setZN(A, false)
                }
            }
        }
    
    private func sbc(_ operand: UInt16) {
        let inverted = ~operand
        adc(inverted)
    }
    
    private func and(_ operand: UInt16) {
        A &= operand
        setZN(A, acc8)
    }
    
    private func eor(_ operand: UInt16) {
        A ^= operand
        setZN(A, acc8)
    }
    
    private func ora(_ operand: UInt16) {
        A |= operand
        setZN(A, acc8)
    }
    
    private func cmp(_ reg: UInt16, _ operand: UInt16, _ is8bit: Bool) {
        let result = reg &- operand
        P.remove([.c, .n, .z])
        if reg >= operand { P.insert(.c) }
        setZN(result, is8bit)
    }
    
    private func asl(_ value: UInt16, _ is8bit: Bool, _ isAcc: Bool) -> UInt16 {
        let masked = is8bit ? value & 0xFF : value
        P.remove(.c)
        if (masked & (is8bit ? 0x80 : 0x8000)) != 0 { P.insert(.c) }
        let result = masked &<< 1
        setZN(result, is8bit)
        if isAcc { return result }
        if is8bit { writeByte(addr, UInt8(result)) } else { writeWord(addr, result) }
        return result
    }
    
    private func lsr(_ value: UInt16, _ is8bit: Bool, _ isAcc: Bool) -> UInt16 {
        let masked = is8bit ? value & 0xFF : value
        P.remove(.c)
        if (masked & 1) != 0 { P.insert(.c) }
        let result = masked >> 1
        setZN(result, is8bit)
        if isAcc { return result }
        if is8bit { writeByte(addr, UInt8(result)) } else { writeWord(addr, result) }
        return result
    }
    
    private func rol(_ value: UInt16, _ is8bit: Bool, _ isAcc: Bool) -> UInt16 {
        let masked = is8bit ? value & 0xFF : value
        let carry = P.contains(.c) ? 1 : 0
        P.remove(.c)
        if (masked & (is8bit ? 0x80 : 0x8000)) != 0 { P.insert(.c) }
        let result = (masked &<< 1) | UInt16(carry)
        setZN(result, is8bit)
        if isAcc { return result }
        if is8bit { writeByte(addr, UInt8(result)) } else { writeWord(addr, result) }
        return result
    }
    
    private func ror(_ value: UInt16, _ is8bit: Bool, _ isAcc: Bool) -> UInt16 {
        let masked = is8bit ? value & 0xFF : value
        let carry = P.contains(.c) ? UInt16(1 << (is8bit ? 7 : 15)) : 0
        P.remove(.c)
        if (masked & 1) != 0 { P.insert(.c) }
        let result = (masked >> 1) | carry
        setZN(result, is8bit)
        if isAcc { return result }
        if is8bit { writeByte(addr, UInt8(result)) } else { writeWord(addr, result) }
        return result
    }
    
    private func inc(_ value: UInt16, _ is8bit: Bool) -> UInt16 {
        let result = value &+ 1
        setZN(result, is8bit)
        if is8bit { writeByte(addr, UInt8(result)) } else { writeWord(addr, result) }
        return result
    }
    
    private func dec(_ value: UInt16, _ is8bit: Bool) -> UInt16 {
        let result = value &- 1
        setZN(result, is8bit)
        if is8bit { writeByte(addr, UInt8(result)) } else { writeWord(addr, result) }
        return result
    }
    
    private func branch(_ condition: Bool, _ offset: Int8) {
            if condition {
                let oldPC = PC
                let jump = Int(offset) // Convert Int8 to Int
                let current = Int(PC)
                let result = current + jump
                PC = UInt16(result & 0xFFFF)
                
                if ((oldPC ^ PC) & 0xFF00) != 0 { cycles += 1 }
                cycles += 1
            }
        }
    
    private func jmp() {
        PC = UInt16(addr & 0xFFFF)
    }
    
    private func jsr() {
        let target = UInt16(addr & 0xFFFF)
        pushWord(PC - 1)
        PC = target
    }
    
    private func jsl() {
        let target = addr
        pushByte(PB)
        pushWord(PC - 1)
        PB = UInt8(target >> 16)
        PC = UInt16(target & 0xFFFF)
    }
    
    private func rts() {
        PC = popWord() &+ 1
    }
    
    private func rtl() {
        PC = popWord() &+ 1
        PB = popByte()
    }
    
    private func tax() {
        X = A
        setZN(X, idx8)
    }
    
    private func tay() {
        Y = A
        setZN(Y, idx8)
    }
    
    private func txa() {
        A = X
        setZN(A, acc8)
    }
    
    private func tya() {
        A = Y
        setZN(A, acc8)
    }
    
    private func tsx() {
        X = S
        setZN(X, idx8)
    }
    
    private func txs() {
        S = X
    }
    
    private func tcd() {
        D = A
        setZN(D, false)
    }
    
    private func tdc() {
        A = D
        setZN(A, false)
    }
    
    private func tcs() {
        S = A
    }
    
    private func tsc() {
        A = S
        setZN(A, false)
    }
    
    private func pha() {
        if acc8 { pushByte(UInt8(A)) } else { pushWord(A) }
    }
    
    private func pla() {
        A = acc8 ? UInt16(popByte()) : popWord()
        setZN(A, acc8)
    }
    
    private func phx() {
        if idx8 { pushByte(UInt8(X)) } else { pushWord(X) }
    }
    
    private func plx() {
        X = idx8 ? UInt16(popByte()) : popWord()
        setZN(X, idx8)
    }
    
    private func phy() {
        if idx8 { pushByte(UInt8(Y)) } else { pushWord(Y) }
    }
    
    private func ply() {
        Y = idx8 ? UInt16(popByte()) : popWord()
        setZN(Y, idx8)
    }
    
    private func php() {
        pushStatus()
    }
    
    private func plp() {
        let flags = popByte()
        P = Flags(rawValue: flags & 0xCF)
        if e { P.insert([.m, .x]) }
        adjustRegisters()
    }
    
    private func phb() {
        pushByte(DB)
    }
    
    private func plb() {
        DB = popByte()
        setZN(UInt16(DB), true)
    }
    
    private func phd() {
        pushWord(D)
    }
    
    private func pld() {
        D = popWord()
        setZN(D, false)
    }
    
    private func clc() { P.remove(.c); cycles += 2 }
    private func sec() { P.insert(.c); cycles += 2 }
    private func cli() { P.remove(.i); cycles += 2 }
    private func sei() { P.insert(.i); cycles += 2 }
    private func clv() { P.remove(.v); cycles += 2 }
    private func cld() { P.remove(.d); cycles += 2 }
    private func sed() { P.insert(.d); cycles += 2 }
    
    private func rep(_ mask: UInt8) {
        P.remove(Flags(rawValue: mask))
        adjustRegisters()
        cycles += 3
    }
    
    private func sep(_ mask: UInt8) {
        P.insert(Flags(rawValue: mask))
        adjustRegisters()
        cycles += 3
    }
    
    private func xce() {
        let oldE = e
        let oldC = P.contains(.c)
        e = oldC
        if oldE {
            P.insert(.c)
        } else {
            P.remove(.c)
        }
        if oldE && !e {
            P.insert([.m, .x])
        }
        adjustRegisters()
        cycles += 2
    }
    
    private func xba() {
        let low = A & 0xFF
        let high = (A >> 8) & 0xFF
        A = (low << 8) | UInt16(high)
        setZN(UInt16(high), true)
        cycles += 3
    }
    
    private func mvn() {
        let dstBank = fetchByte()
        let srcBank = fetchByte()
        DB = dstBank
        let count = A
        var srcOff = X
        var dstOff = Y
        for _ in 0..<count {
            let value = readByte((UInt32(srcBank) << 16) | UInt32(srcOff))
            writeByte((UInt32(dstBank) << 16) | UInt32(dstOff), value)
            srcOff &+= 1
            dstOff &+= 1
        }
        X = srcOff
        Y = dstOff
        A = 0
        cycles += Int(count) * 7
    }
    
    private func mvp() {
        let dstBank = fetchByte()
        let srcBank = fetchByte()
        DB = dstBank
        let count = A
        var srcOff = X
        var dstOff = Y
        for _ in 0..<count {
            let value = readByte((UInt32(srcBank) << 16) | UInt32(srcOff))
            writeByte((UInt32(dstBank) << 16) | UInt32(dstOff), value)
            srcOff &-= 1
            dstOff &-= 1
        }
        X = srcOff
        Y = dstOff
        A = 0
        cycles += Int(count) * 7
    }
    
    private func bit(_ operand: UInt16) {
        let result = A & operand
        P.remove([.n, .v, .z])
        setZN(result, acc8)
        if !acc8 {
            P.formUnion(Flags(rawValue: UInt8(operand >> 8)))
        } else {
            P.formUnion(Flags(rawValue: UInt8(operand) & 0xC0))
        }
    }
    
    private func nop() { cycles += 2 }
    
    private func brk() {
        _ = fetchByte()
        pushPB()
        pushWord(PC)
        pushStatus()
        P.insert(.i)
        PB = 0
        if e {
            PC = bus.readWord(0xFFFE)
        } else {
            PC = bus.readWord(0xFFE6)
        }
        cycles += 7
    }
    
    private func cop() {
        _ = fetchByte()
        pushPB()
        pushWord(PC)
        pushStatus()
        P.insert(.i)
        PB = 0
        if e {
            PC = bus.readWord(0xFFF4)
        } else {
            PC = bus.readWord(0xFFE4)
        }
        cycles += 7
    }
    
    private func wai() {
        waiting = true
        cycles += 3
    }
    
    private func stp() {
        stopped = true
        cycles += 3
    }
    
    private func rti() {
        P = Flags(rawValue: popByte())
        PC = popWord()
        if !e { PB = popByte() }
        if e { P.insert([.m, .x]) }
        adjustRegisters()
        cycles += 6
    }
    
    private func tsb() {
        let value = readWord(addr)
        P.remove(.z)
        if (value & A) == 0 { P.insert(.z) }
        let result = value | A
        writeWord(addr, result)
    }
    
    private func trb() {
        let value = readWord(addr)
        P.remove(.z)
        if (value & A) == 0 { P.insert(.z) }
        let result = value & ~A
        writeWord(addr, result)
    }
    
    private func pei() {
        let zp = fetchByte()
        pushWord(UInt16(zp) + 1)
        cycles += 5
    }
    
    private func per(_ offset: Int16) {
        let target = PC &+ UInt16(bitPattern: offset)
        pushWord(PC)
        PC = target
        cycles += 6
    }
    
    private func pea(_ value: UInt16) {
        pushWord(value)
    }
    
    private func phk() {
        pushByte(PB)
        cycles += 3
    }
    
    private func illegalOpcode() {
        cycles += 2
    }
    
    
    private func setupOpcodeTable() {
        opcodeTable[0xA9] = { self.imm(self.acc8); self.lda(); self.cycles += 2 }
        opcodeTable[0xAD] = { self.abs(); self.lda(); self.cycles += 4 }
        opcodeTable[0xAF] = { self.longAddr(); self.lda(); self.cycles += 5 }
        opcodeTable[0xA5] = { self.addr = self.dp(UInt16(self.fetchByte())); self.lda(); self.cycles += 3 }
        opcodeTable[0xB5] = { let off = UInt16(self.fetchByte()); self.addr = self.dp(off) &+ UInt32(self.X); self.lda(); self.cycles += 4 }
        opcodeTable[0xA7] = { let off = UInt16(self.fetchByte()); self.addr = self.indirectLong(off); self.lda(); self.cycles += 6 }
        opcodeTable[0xB7] = { let off = UInt16(self.fetchByte()); let base = self.readWord(self.dp(off)); let eff = base &+ self.Y; self.addr = (UInt32(self.DB) << 16) | UInt32(eff); if !self.idx8 && (base & 0xFF00) != (eff & 0xFF00) { self.cycles += 1 }; self.lda(); self.cycles += 5 }
        opcodeTable[0xB2] = { let off = UInt16(self.fetchByte()); self.addr = self.indirect(off); self.lda(); self.cycles += 5 }
        opcodeTable[0xB3] = { let off = UInt16(self.fetchByte()); let base = self.readWord(self.dp(off)); let eff = base &+ self.Y; self.addr = (UInt32(self.DB) << 16) | UInt32(eff); if !self.idx8 && (base & 0xFF00) != (eff & 0xFF00) { self.cycles += 1 }; self.lda(); self.cycles += 6 }
        opcodeTable[0xA3] = { let off = self.fetchByte(); self.addr = UInt32(self.S &+ UInt16(off)); self.lda(); self.cycles += 4 }
        opcodeTable[0xB3] = { let off = self.fetchByte(); let base = self.readWord(UInt32(self.S &+ UInt16(off))); let eff = base &+ self.Y; self.addr = (UInt32(self.DB) << 16) | UInt32(eff); if !self.idx8 && (base & 0xFF00) != (eff & 0xFF00) { self.cycles += 1 }; self.lda(); self.cycles += 7 }
        opcodeTable[0xBF] = { self.longAddr(); self.addr += UInt32(self.X); self.lda(); self.cycles += 6 }
        
        opcodeTable[0x8D] = { self.abs(); self.sta(); self.cycles += 4 }
        opcodeTable[0x8F] = { self.longAddr(); self.sta(); self.cycles += 5 }
        opcodeTable[0x85] = { self.addr = self.dp(UInt16(self.fetchByte())); self.sta(); self.cycles += 3 }
        opcodeTable[0x95] = { let off = UInt16(self.fetchByte()); self.addr = self.dp(off) &+ UInt32(self.X); self.sta(); self.cycles += 4 }
        opcodeTable[0x92] = { let off = UInt16(self.fetchByte()); self.addr = self.indirect(off); self.sta(); self.cycles += 5 }
        opcodeTable[0x83] = { let off = self.fetchByte(); self.addr = UInt32(self.S &+ UInt16(off)); self.sta(); self.cycles += 4 }
        opcodeTable[0x93] = { let off = self.fetchByte(); let base = self.readWord(UInt32(self.S &+ UInt16(off))); let eff = base &+ self.Y; self.addr = (UInt32(self.DB) << 16) | UInt32(eff); self.sta(); self.cycles += 7 }
        opcodeTable[0x87] = { let off = UInt16(self.fetchByte()); self.addr = self.indirectLong(off); self.sta(); self.cycles += 6 }
        opcodeTable[0x97] = { let off = UInt16(self.fetchByte()); let base = self.readWord(self.dp(off)); let eff = base &+ self.Y; self.addr = (UInt32(self.DB) << 16) | UInt32(eff); self.sta(); self.cycles += 6 }
        
        opcodeTable[0xA2] = { self.imm(self.idx8); self.ldx(); self.cycles += 2 }
        opcodeTable[0xAE] = { self.abs(); self.ldx(); self.cycles += 4 }
        opcodeTable[0xA6] = { self.addr = self.dp(UInt16(self.fetchByte())); self.ldx(); self.cycles += 3 }
        opcodeTable[0xB6] = { let off = UInt16(self.fetchByte()); self.addr = self.dp(off) &+ UInt32(self.Y); self.ldx(); self.cycles += 4 }
        opcodeTable[0xBE] = { let pageCross = self.absIdx(self.Y); self.ldx(); self.cycles += pageCross ? 5 : 4 }
        
        opcodeTable[0x8E] = { self.abs(); self.stx(); self.cycles += 4 }
        opcodeTable[0x86] = { self.addr = self.dp(UInt16(self.fetchByte())); self.stx(); self.cycles += 3 }
        opcodeTable[0x96] = { let off = UInt16(self.fetchByte()); self.addr = self.dp(off) &+ UInt32(self.Y); self.stx(); self.cycles += 4 }
        
        opcodeTable[0xA0] = { self.imm(self.idx8); self.ldy(); self.cycles += 2 }
        opcodeTable[0xAC] = { self.abs(); self.ldy(); self.cycles += 4 }
        opcodeTable[0xA4] = { self.addr = self.dp(UInt16(self.fetchByte())); self.ldy(); self.cycles += 3 }
        opcodeTable[0xB4] = { let off = UInt16(self.fetchByte()); self.addr = self.dp(off) &+ UInt32(self.X); self.ldy(); self.cycles += 4 }
        opcodeTable[0xBC] = { let pageCross = self.absIdx(self.X); self.ldy(); self.cycles += pageCross ? 5 : 4 }
        
        opcodeTable[0x8C] = { self.abs(); self.sty(); self.cycles += 4 }
        opcodeTable[0x84] = { self.addr = self.dp(UInt16(self.fetchByte())); self.sty(); self.cycles += 3 }
        opcodeTable[0x94] = { let off = UInt16(self.fetchByte()); self.addr = self.dp(off) &+ UInt32(self.X); self.sty(); self.cycles += 4 }
        
        opcodeTable[0x9C] = { self.abs(); self.writeWord(self.addr, 0); self.cycles += 4 }
        opcodeTable[0x9E] = { let off = UInt16(self.fetchByte()); self.addr = self.dp(off) &+ UInt32(self.X); self.writeWord(self.addr, 0); self.cycles += 4 }
        opcodeTable[0x64] = { self.addr = self.dp(UInt16(self.fetchByte())); self.writeWord(self.addr, 0); self.cycles += 3 }
        opcodeTable[0x74] = { let off = UInt16(self.fetchByte()); self.addr = self.dp(off) &+ UInt32(self.X); self.writeWord(self.addr, 0); self.cycles += 4 }
        
        opcodeTable[0x69] = { self.imm(self.acc8); self.adc(UInt16(self.acc8 ? UInt16(self.fetchByte()) : self.fetchWord())); self.cycles += 2 }
        opcodeTable[0x6D] = { self.abs(); self.adc(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 4 }
        opcodeTable[0x6F] = { self.longAddr(); self.adc(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 5 }
        opcodeTable[0x65] = { self.addr = self.dp(UInt16(self.fetchByte())); self.adc(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 3 }
        opcodeTable[0x75] = { let off = UInt16(self.fetchByte()); self.addr = self.dp(off) &+ UInt32(self.X); self.adc(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 4 }
        opcodeTable[0x72] = { let off = UInt16(self.fetchByte()); self.addr = self.indirect(off); self.adc(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 5 }
        opcodeTable[0x67] = { let off = UInt16(self.fetchByte()); self.addr = self.indirectLong(off); self.adc(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 6 }
        opcodeTable[0x77] = { let off = UInt16(self.fetchByte()); let base = self.readWord(self.dp(off)); let eff = base &+ self.Y; self.addr = (UInt32(self.DB) << 16) | UInt32(eff); if !self.idx8 && (base & 0xFF00) != (eff & 0xFF00) { self.cycles += 1 }; self.adc(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 5 }
        opcodeTable[0x63] = { let off = self.fetchByte(); self.addr = UInt32(self.S &+ UInt16(off)); self.adc(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 4 }
        opcodeTable[0x73] = { let off = self.fetchByte(); let base = self.readWord(UInt32(self.S &+ UInt16(off))); let eff = base &+ self.Y; self.addr = (UInt32(self.DB) << 16) | UInt32(eff); if !self.idx8 && (base & 0xFF00) != (eff & 0xFF00) { self.cycles += 1 }; self.adc(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 6 }
        opcodeTable[0x6B] = { let off = UInt16(self.fetchByte()); self.addr = self.indirectLong(off) &+ UInt32(self.Y); self.adc(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 6 }
        
        opcodeTable[0xE9] = { self.imm(self.acc8); self.sbc(UInt16(self.acc8 ? UInt16(self.fetchByte()) : self.fetchWord())); self.cycles += 2 }
        opcodeTable[0xED] = { self.abs(); self.sbc(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 4 }
        opcodeTable[0xEF] = { self.longAddr(); self.sbc(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 5 }
        opcodeTable[0xE5] = { self.addr = self.dp(UInt16(self.fetchByte())); self.sbc(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 3 }
        opcodeTable[0xF5] = { let off = UInt16(self.fetchByte()); self.addr = self.dp(off) &+ UInt32(self.X); self.sbc(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 4 }
        opcodeTable[0xF2] = { let off = UInt16(self.fetchByte()); self.addr = self.indirect(off); self.sbc(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 5 }
        opcodeTable[0xE7] = { let off = UInt16(self.fetchByte()); self.addr = self.indirectLong(off); self.sbc(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 6 }
        opcodeTable[0xF7] = { let off = UInt16(self.fetchByte()); let base = self.readWord(self.dp(off)); let eff = base &+ self.Y; self.addr = (UInt32(self.DB) << 16) | UInt32(eff); if !self.idx8 && (base & 0xFF00) != (eff & 0xFF00) { self.cycles += 1 }; self.sbc(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 5 }
        opcodeTable[0xE3] = { let off = self.fetchByte(); self.addr = UInt32(self.S &+ UInt16(off)); self.sbc(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 4 }
        opcodeTable[0xF3] = { let off = self.fetchByte(); let base = self.readWord(UInt32(self.S &+ UInt16(off))); let eff = base &+ self.Y; self.addr = (UInt32(self.DB) << 16) | UInt32(eff); if !self.idx8 && (base & 0xFF00) != (eff & 0xFF00) { self.cycles += 1 }; self.sbc(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 6 }
        
        opcodeTable[0x29] = { self.imm(self.acc8); self.and(UInt16(self.acc8 ? UInt16(self.fetchByte()) : self.fetchWord())); self.cycles += 2 }
        opcodeTable[0x2D] = { self.abs(); self.and(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 4 }
        opcodeTable[0x2F] = { self.longAddr(); self.and(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 5 }
        opcodeTable[0x25] = { self.addr = self.dp(UInt16(self.fetchByte())); self.and(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 3 }
        opcodeTable[0x35] = { let off = UInt16(self.fetchByte()); self.addr = self.dp(off) &+ UInt32(self.X); self.and(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 4 }
        opcodeTable[0x32] = { let off = UInt16(self.fetchByte()); self.addr = self.indirect(off); self.and(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 5 }
        opcodeTable[0x27] = { let off = UInt16(self.fetchByte()); self.addr = self.indirectLong(off); self.and(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 6 }
        opcodeTable[0x37] = { let off = UInt16(self.fetchByte()); let base = self.readWord(self.dp(off)); let eff = base &+ self.Y; self.addr = (UInt32(self.DB) << 16) | UInt32(eff); if !self.idx8 && (base & 0xFF00) != (eff & 0xFF00) { self.cycles += 1 }; self.and(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 5 }
        opcodeTable[0x23] = { let off = self.fetchByte(); self.addr = UInt32(self.S &+ UInt16(off)); self.and(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 4 }
        opcodeTable[0x33] = { let off = self.fetchByte(); let base = self.readWord(UInt32(self.S &+ UInt16(off))); let eff = base &+ self.Y; self.addr = (UInt32(self.DB) << 16) | UInt32(eff); if !self.idx8 && (base & 0xFF00) != (eff & 0xFF00) { self.cycles += 1 }; self.and(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 6 }
        
        opcodeTable[0x49] = { self.imm(self.acc8); self.eor(UInt16(self.acc8 ? UInt16(self.fetchByte()) : self.fetchWord())); self.cycles += 2 }
        opcodeTable[0x4D] = { self.abs(); self.eor(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 4 }
        opcodeTable[0x4F] = { self.longAddr(); self.eor(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 5 }
        opcodeTable[0x45] = { self.addr = self.dp(UInt16(self.fetchByte())); self.eor(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 3 }
        opcodeTable[0x55] = { let off = UInt16(self.fetchByte()); self.addr = self.dp(off) &+ UInt32(self.X); self.eor(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 4 }
        opcodeTable[0x52] = { let off = UInt16(self.fetchByte()); self.addr = self.indirect(off); self.eor(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 5 }
        opcodeTable[0x47] = { let off = UInt16(self.fetchByte()); self.addr = self.indirectLong(off); self.eor(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 6 }
        opcodeTable[0x57] = { let off = UInt16(self.fetchByte()); let base = self.readWord(self.dp(off)); let eff = base &+ self.Y; self.addr = (UInt32(self.DB) << 16) | UInt32(eff); if !self.idx8 && (base & 0xFF00) != (eff & 0xFF00) { self.cycles += 1 }; self.eor(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 5 }
        opcodeTable[0x43] = { let off = self.fetchByte(); self.addr = UInt32(self.S &+ UInt16(off)); self.eor(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 4 }
        opcodeTable[0x53] = { let off = self.fetchByte(); let base = self.readWord(UInt32(self.S &+ UInt16(off))); let eff = base &+ self.Y; self.addr = (UInt32(self.DB) << 16) | UInt32(eff); if !self.idx8 && (base & 0xFF00) != (eff & 0xFF00) { self.cycles += 1 }; self.eor(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 6 }
        
        opcodeTable[0x09] = { self.imm(self.acc8); self.ora(UInt16(self.acc8 ? UInt16(self.fetchByte()) : self.fetchWord())); self.cycles += 2 }
        opcodeTable[0x0D] = { self.abs(); self.ora(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 4 }
        opcodeTable[0x0F] = { self.longAddr(); self.ora(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 5 }
        opcodeTable[0x05] = { self.addr = self.dp(UInt16(self.fetchByte())); self.ora(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 3 }
        opcodeTable[0x15] = { let off = UInt16(self.fetchByte()); self.addr = self.dp(off) &+ UInt32(self.X); self.ora(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 4 }
        opcodeTable[0x12] = { let off = UInt16(self.fetchByte()); self.addr = self.indirect(off); self.ora(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 5 }
        opcodeTable[0x07] = { let off = UInt16(self.fetchByte()); self.addr = self.indirectLong(off); self.ora(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 6 }
        opcodeTable[0x17] = { let off = UInt16(self.fetchByte()); let base = self.readWord(self.dp(off)); let eff = base &+ self.Y; self.addr = (UInt32(self.DB) << 16) | UInt32(eff); if !self.idx8 && (base & 0xFF00) != (eff & 0xFF00) { self.cycles += 1 }; self.ora(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 5 }
        opcodeTable[0x03] = { let off = self.fetchByte(); self.addr = UInt32(self.S &+ UInt16(off)); self.ora(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 4 }
        opcodeTable[0x13] = { let off = self.fetchByte(); let base = self.readWord(UInt32(self.S &+ UInt16(off))); let eff = base &+ self.Y; self.addr = (UInt32(self.DB) << 16) | UInt32(eff); if !self.idx8 && (base & 0xFF00) != (eff & 0xFF00) { self.cycles += 1 }; self.ora(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 6 }
        
        opcodeTable[0xC9] = { self.imm(self.acc8); self.cmp(self.A, UInt16(self.acc8 ? UInt16(self.fetchByte()) : self.fetchWord()), self.acc8); self.cycles += 2 }
        opcodeTable[0xCD] = { self.abs(); self.cmp(self.A, self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr), self.acc8); self.cycles += 4 }
        opcodeTable[0xCF] = { self.longAddr(); self.cmp(self.A, self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr), self.acc8); self.cycles += 5 }
        opcodeTable[0xC5] = { self.addr = self.dp(UInt16(self.fetchByte())); self.cmp(self.A, self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr), self.acc8); self.cycles += 3 }
        opcodeTable[0xD5] = { let off = UInt16(self.fetchByte()); self.addr = self.dp(off) &+ UInt32(self.X); self.cmp(self.A, self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr), self.acc8); self.cycles += 4 }
        opcodeTable[0xD2] = { let off = UInt16(self.fetchByte()); self.addr = self.indirect(off); self.cmp(self.A, self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr), self.acc8); self.cycles += 5 }
        opcodeTable[0xC7] = { let off = UInt16(self.fetchByte()); self.addr = self.indirectLong(off); self.cmp(self.A, self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr), self.acc8); self.cycles += 6 }
        opcodeTable[0xD7] = { let off = UInt16(self.fetchByte()); let base = self.readWord(self.dp(off)); let eff = base &+ self.Y; self.addr = (UInt32(self.DB) << 16) | UInt32(eff); if !self.idx8 && (base & 0xFF00) != (eff & 0xFF00) { self.cycles += 1 }; self.cmp(self.A, self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr), self.acc8); self.cycles += 5 }
        opcodeTable[0xC3] = { let off = self.fetchByte(); self.addr = UInt32(self.S &+ UInt16(off)); self.cmp(self.A, self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr), self.acc8); self.cycles += 4 }
        opcodeTable[0xD3] = { let off = self.fetchByte(); let base = self.readWord(UInt32(self.S &+ UInt16(off))); let eff = base &+ self.Y; self.addr = (UInt32(self.DB) << 16) | UInt32(eff); if !self.idx8 && (base & 0xFF00) != (eff & 0xFF00) { self.cycles += 1 }; self.cmp(self.A, self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr), self.acc8); self.cycles += 6 }
        
        opcodeTable[0xE0] = { self.imm(self.idx8); self.cmp(self.X, UInt16(self.idx8 ? UInt16(self.fetchByte()) : self.fetchWord()), self.idx8); self.cycles += 2 }
        opcodeTable[0xEC] = { self.abs(); self.cmp(self.X, self.idx8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr), self.idx8); self.cycles += 4 }
        opcodeTable[0xE4] = { self.addr = self.dp(UInt16(self.fetchByte())); self.cmp(self.X, self.idx8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr), self.idx8); self.cycles += 3 }
        
        opcodeTable[0xC0] = { self.imm(self.idx8); self.cmp(self.Y, UInt16(self.idx8 ? UInt16(self.fetchByte()) : self.fetchWord()), self.idx8); self.cycles += 2 }
        opcodeTable[0xCC] = { self.abs(); self.cmp(self.Y, self.idx8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr), self.idx8); self.cycles += 4 }
        opcodeTable[0xC4] = { self.addr = self.dp(UInt16(self.fetchByte())); self.cmp(self.Y, self.idx8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr), self.idx8); self.cycles += 3 }
        
        opcodeTable[0x10] = { let off = Int8(bitPattern: self.fetchByte()); self.branch(!self.P.contains(.n), off); self.cycles += 2 }
        opcodeTable[0x30] = { let off = Int8(bitPattern: self.fetchByte()); self.branch(self.P.contains(.n), off); self.cycles += 2 }
        opcodeTable[0x50] = { let off = Int8(bitPattern: self.fetchByte()); self.branch(!self.P.contains(.v), off); self.cycles += 2 }
        opcodeTable[0x70] = { let off = Int8(bitPattern: self.fetchByte()); self.branch(self.P.contains(.v), off); self.cycles += 2 }
        opcodeTable[0x90] = { let off = Int8(bitPattern: self.fetchByte()); self.branch(!self.P.contains(.c), off); self.cycles += 2 }
        opcodeTable[0xB0] = { let off = Int8(bitPattern: self.fetchByte()); self.branch(self.P.contains(.c), off); self.cycles += 2 }
        opcodeTable[0xD0] = { let off = Int8(bitPattern: self.fetchByte()); self.branch(!self.P.contains(.z), off); self.cycles += 2 }
        opcodeTable[0xF0] = { let off = Int8(bitPattern: self.fetchByte()); self.branch(self.P.contains(.z), off); self.cycles += 2 }
        opcodeTable[0x80] = { let off = Int8(bitPattern: self.fetchByte()); self.PC = UInt16(Int(self.PC) + Int(off)); self.cycles += 3 }
        opcodeTable[0x82] = { let off = Int16(bitPattern: self.fetchWord()); self.PC = UInt16(Int(self.PC) + Int(off)); self.cycles += 4 }
        opcodeTable[0x1C] = { self.abs(); self.trb(); self.cycles += 6 }
        opcodeTable[0x04] = { self.addr = self.dp(UInt16(self.fetchByte())); self.tsb(); self.cycles += 5 }
        opcodeTable[0x14] = { self.addr = self.dp(UInt16(self.fetchByte())); self.trb(); self.cycles += 5 }
        opcodeTable[0x0C] = { self.abs(); self.tsb(); self.cycles += 6 }
        
        opcodeTable[0x4C] = { self.abs(); self.jmp(); self.cycles += 3 }
        opcodeTable[0x6C] = { let ptr = UInt16(self.fetchWord()); self.PC = self.readWord(UInt32(ptr)); self.cycles += 5 }
        opcodeTable[0x7C] = { let base = UInt16(self.fetchWord()); let ptr = base &+ self.X; self.PC = self.readWord(UInt32(ptr)); self.cycles += 6 }
        opcodeTable[0xDC] = { let off = UInt16(self.fetchWord()); let ptr = self.D &+ off; let lo = self.readByte(UInt32(ptr)); let mid = self.readByte(UInt32(ptr &+ 1)); let hi = self.readByte(UInt32(ptr &+ 2)); self.PC = (UInt16(mid) << 8) | UInt16(lo); self.PB = hi; self.cycles += 6 }
        opcodeTable[0x5C] = { self.longAddr(); self.PB = UInt8(self.addr >> 16); self.PC = UInt16(self.addr); self.cycles += 4 }
        
        opcodeTable[0x20] = { self.abs(); self.jsr(); self.cycles += 6 }
        opcodeTable[0x22] = { self.longAddr(); self.jsl(); self.cycles += 8 }
        
        opcodeTable[0x60] = { self.rts(); self.cycles += 6 }
        opcodeTable[0x6B] = { self.rtl(); self.cycles += 7 }
        opcodeTable[0x40] = { self.rti(); self.cycles += 6 }
        
        opcodeTable[0x48] = { self.pha(); self.cycles += self.acc8 ? 3 : 4 }
        opcodeTable[0x68] = { self.pla(); self.cycles += self.acc8 ? 4 : 5 }
        opcodeTable[0xDA] = { self.phx(); self.cycles += self.idx8 ? 3 : 4 }
        opcodeTable[0xFA] = { self.plx(); self.cycles += self.idx8 ? 4 : 5 }
        opcodeTable[0x5A] = { self.phy(); self.cycles += self.idx8 ? 3 : 4 }
        opcodeTable[0x7A] = { self.ply(); self.cycles += self.idx8 ? 4 : 5 }
        opcodeTable[0x08] = { self.php(); self.cycles += 3 }
        opcodeTable[0x28] = { self.plp(); self.cycles += 4 }
        opcodeTable[0x8B] = { self.phb(); self.cycles += 3 }
        opcodeTable[0xAB] = { self.plb(); self.cycles += 4 }
        opcodeTable[0x0B] = { self.phd(); self.cycles += 4 }
        opcodeTable[0x2B] = { self.pld(); self.cycles += 5 }
        opcodeTable[0xD4] = { self.pei() }
        
        opcodeTable[0xAA] = { self.tax(); self.cycles += 2 }
        opcodeTable[0xA8] = { self.tay(); self.cycles += 2 }
        opcodeTable[0xBA] = { self.tsx(); self.cycles += 2 }
        opcodeTable[0x8A] = { self.txa(); self.cycles += 2 }
        opcodeTable[0x9A] = { self.txs(); self.cycles += 2 }
        opcodeTable[0x98] = { self.tya(); self.cycles += 2 }
        opcodeTable[0x1B] = { self.tcs(); self.cycles += 2 }
        opcodeTable[0x3B] = { self.tsc(); self.cycles += 2 }
        opcodeTable[0x5B] = { self.tcd(); self.cycles += 2 }
        opcodeTable[0x7B] = { self.tdc(); self.cycles += 2 }
        
        opcodeTable[0x18] = { self.clc() }
        opcodeTable[0x38] = { self.sec() }
        opcodeTable[0x58] = { self.cli() }
        opcodeTable[0x78] = { self.sei() }
        opcodeTable[0xB8] = { self.clv(); self.cycles += 2 }
        opcodeTable[0xD8] = { self.cld() }
        opcodeTable[0xF8] = { self.sed() }
        
        opcodeTable[0xC2] = { self.rep(self.fetchByte()); }
        opcodeTable[0xE2] = { self.sep(self.fetchByte()); }
        opcodeTable[0xFB] = { self.xce() }
        opcodeTable[0xEB] = { self.xba(); self.cycles += 3 }
        opcodeTable[0x42] = { _ = self.fetchByte(); self.cycles += 2 }
        
        opcodeTable[0x54] = { self.mvn(); }
        opcodeTable[0x44] = { self.mvp(); }
        
        opcodeTable[0x0A] = { self.A = self.asl(self.A, self.acc8, true); self.cycles += 2 }
        opcodeTable[0x0E] = { self.abs(); let val = self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr); _ = self.asl(val, self.acc8, false); self.cycles += 6 }
        opcodeTable[0x06] = { self.addr = self.dp(UInt16(self.fetchByte())); let val = self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr); _ = self.asl(val, self.acc8, false); self.cycles += 5 }
        opcodeTable[0x16] = { let off = UInt16(self.fetchByte()); self.addr = self.dp(off) &+ UInt32(self.X); let val = self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr); _ = self.asl(val, self.acc8, false); self.cycles += 6 }
        opcodeTable[0x1E] = { let pageCross = self.absIdx(self.X); let val = self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr); _ = self.asl(val, self.acc8, false); self.cycles += pageCross ? 7 : 6 }
        
        opcodeTable[0x4A] = { self.A = self.lsr(self.A, self.acc8, true); self.cycles += 2 }
        opcodeTable[0x4E] = { self.abs(); let val = self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr); _ = self.lsr(val, self.acc8, false); self.cycles += 6 }
        opcodeTable[0x46] = { self.addr = self.dp(UInt16(self.fetchByte())); let val = self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr); _ = self.lsr(val, self.acc8, false); self.cycles += 5 }
        opcodeTable[0x56] = { let off = UInt16(self.fetchByte()); self.addr = self.dp(off) &+ UInt32(self.X); let val = self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr); _ = self.lsr(val, self.acc8, false); self.cycles += 6 }
        opcodeTable[0x5E] = { let pageCross = self.absIdx(self.X); let val = self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr); _ = self.lsr(val, self.acc8, false); self.cycles += pageCross ? 7 : 6 }
        
        opcodeTable[0x2A] = { self.A = self.rol(self.A, self.acc8, true); self.cycles += 2 }
        opcodeTable[0x2E] = { self.abs(); let val = self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr); _ = self.rol(val, self.acc8, false); self.cycles += 6 }
        opcodeTable[0x26] = { self.addr = self.dp(UInt16(self.fetchByte())); let val = self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr); _ = self.rol(val, self.acc8, false); self.cycles += 5 }
        opcodeTable[0x36] = { let off = UInt16(self.fetchByte()); self.addr = self.dp(off) &+ UInt32(self.X); let val = self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr); _ = self.rol(val, self.acc8, false); self.cycles += 6 }
        opcodeTable[0x3E] = { let pageCross = self.absIdx(self.X); let val = self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr); _ = self.rol(val, self.acc8, false); self.cycles += pageCross ? 7 : 6 }
        
        opcodeTable[0x6A] = { self.A = self.ror(self.A, self.acc8, true); self.cycles += 2 }
        opcodeTable[0x6E] = { self.abs(); let val = self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr); _ = self.ror(val, self.acc8, false); self.cycles += 6 }
        opcodeTable[0x66] = { self.addr = self.dp(UInt16(self.fetchByte())); let val = self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr); _ = self.ror(val, self.acc8, false); self.cycles += 5 }
        opcodeTable[0x76] = { let off = UInt16(self.fetchByte()); self.addr = self.dp(off) &+ UInt32(self.X); let val = self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr); _ = self.ror(val, self.acc8, false); self.cycles += 6 }
        opcodeTable[0x7E] = { let pageCross = self.absIdx(self.X); let val = self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr); _ = self.ror(val, self.acc8, false); self.cycles += pageCross ? 7 : 6 }
        
        opcodeTable[0xEE] = { self.abs(); let val = self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr); _ = self.inc(val, self.acc8); self.cycles += 6 }
        opcodeTable[0xFE] = { let pageCross = self.absIdx(self.X); let val = self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr); _ = self.inc(val, self.acc8); self.cycles += pageCross ? 7 : 6 }
        opcodeTable[0xE6] = { self.addr = self.dp(UInt16(self.fetchByte())); let val = self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr); _ = self.inc(val, self.acc8); self.cycles += 5 }
        opcodeTable[0xF6] = { let off = UInt16(self.fetchByte()); self.addr = self.dp(off) &+ UInt32(self.X); let val = self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr); _ = self.inc(val, self.acc8); self.cycles += 6 }
        
        opcodeTable[0xCE] = { self.abs(); let val = self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr); _ = self.dec(val, self.acc8); self.cycles += 6 }
        opcodeTable[0xDE] = { let pageCross = self.absIdx(self.X); let val = self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr); _ = self.dec(val, self.acc8); self.cycles += pageCross ? 7 : 6 }
        opcodeTable[0xC6] = { self.addr = self.dp(UInt16(self.fetchByte())); let val = self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr); _ = self.dec(val, self.acc8); self.cycles += 5 }
        opcodeTable[0xD6] = { let off = UInt16(self.fetchByte()); self.addr = self.dp(off) &+ UInt32(self.X); let val = self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr); _ = self.dec(val, self.acc8); self.cycles += 6 }
        
        opcodeTable[0x1A] = { self.A = self.inc(self.A, self.acc8); self.cycles += 2 }
        opcodeTable[0x3A] = { self.A = self.dec(self.A, self.acc8); self.cycles += 2 }
        opcodeTable[0xE8] = { self.X = self.inc(self.X, self.idx8); self.cycles += 2 }
        opcodeTable[0xCA] = { self.X = self.dec(self.X, self.idx8); self.cycles += 2 }
        opcodeTable[0xC8] = { self.Y = self.inc(self.Y, self.idx8); self.cycles += 2 }
        opcodeTable[0x88] = { self.Y = self.dec(self.Y, self.idx8); self.cycles += 2 }
        
        opcodeTable[0x89] = { let operand = UInt16(self.fetchByte()); self.bit(operand); self.cycles += 3 }
        opcodeTable[0x2C] = { self.abs(); self.bit(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 4 }
        opcodeTable[0x24] = { self.addr = self.dp(UInt16(self.fetchByte())); self.bit(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 3 }
        opcodeTable[0x34] = { let off = UInt16(self.fetchByte()); self.addr = self.dp(off) &+ UInt32(self.X); self.bit(self.acc8 ? UInt16(self.readByte(self.addr)) : self.readWord(self.addr)); self.cycles += 4 }
        
        opcodeTable[0xEA] = { self.nop() }
        opcodeTable[0x00] = { self.brk() }
        opcodeTable[0x02] = { self.cop() }
        opcodeTable[0xCB] = { self.wai() }
        opcodeTable[0xDB] = { self.stp() }
        opcodeTable[0xF4] = { let off = UInt16(self.fetchByte()); self.addr = self.dp(off) &+ UInt32(self.X); self.pea(UInt16(off)); self.cycles += 5 }
        opcodeTable[0x62] = { let off = Int16(bitPattern: self.fetchWord()); self.per(off); }
        opcodeTable[0x4B] = { self.phk() }
    }
}
