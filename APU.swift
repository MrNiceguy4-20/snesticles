import Foundation

class APU {
    var ram = Array<UInt8>(repeating: 0, count: 64 * 1024)
    var iplRom: [UInt8] = [
        0xCD, 0x00, 0xE4, 0xF8, 0xCD, 0x01, 0xE4, 0xF8, 0x78, 0x00, 0xF4, 0x8F, 0x00, 0xF4, 0x8F, 0xCD,
        0x02, 0xE4, 0xF8, 0xCD, 0x03, 0xE4, 0xF8, 0x8F, 0xAA, 0xF4, 0x8F, 0xBB, 0xF5, 0x78, 0xCC, 0xF4,
        0xD0, 0xFB, 0x2F, 0x10, 0xBA, 0x78, 0xCC, 0xF4, 0xD0, 0xFB, 0x2F, 0x19, 0x8F, 0x00, 0xF6, 0x8F,
        0x00, 0xF7, 0xBA, 0xF4, 0xD0, 0xFC, 0xBA, 0xF4, 0xD0, 0xFB, 0x8A, 0xE4, 0xF6, 0x09, 0x80, 0xD0
    ]
    var a: UInt8 = 0
    var x: UInt8 = 0
    var y: UInt8 = 0
    var sp: UInt8 = 0xEF
    var pc: UInt16 = 0xFFC0

    var psw: UInt8 = 0x20
    var cyclesRemaining: Int = 0
    var portOut = [UInt8](repeating: 0, count: 4)
    var portIn = [UInt8](repeating: 0, count: 4)
    var timerEnabled = [Bool](repeating: false, count: 3)
    var timerTargets = [UInt8](repeating: 0, count: 3)
    var timerCounters = [Int](repeating: 0, count: 3)
    var timerOutputs = [UInt8](repeating: 0, count: 3)
    var timerDividers = [Int](repeating: 0, count: 3)
    var dsp: DSP
    var ports: [UInt8] = [0, 0, 0, 0]
    var spcUploadAddr: UInt16 = 0

    var cpuToSpcToggle: [UInt8] = [0, 0, 0, 0]
    var spcToCpuToggle: [UInt8] = [0, 0, 0, 0]

    enum AddressingMode {
        case immediate
        case dp
        case dpX
        case dpY
        case absolute
        case absoluteX
        case absoluteY
        case indirectX
        case indirectY
        case indirectAbsX
        case indirectAbs
        case indirectZeroPage
        case indirectDp
    }

    enum ShiftRotateMode {
        case asl
        case lsr
        case rol
        case ror
    }

    init(dsp: DSP) {
        self.dsp = dsp
        self.dsp.setAPU(self)
        reset()
    }

    func save(_ s: Serializer) {
        s.writeBytes(ram)
        s.write8(a)
        s.write8(x)
        s.write8(y)
        s.write8(sp)
        s.write16(pc)
        s.write8(psw)
        s.writeBytes(portOut)
        s.writeBytes(portIn)
    }

    func load(_ s: Serializer) {
        ram = s.readBytes(64 * 1024)
        a = s.read8()
        x = s.read8()
        y = s.read8()
        sp = s.read8()
        pc = s.read16()
        psw = s.read8()
        portOut = s.readBytes(4)
        portIn = s.readBytes(4)
    }

    func reset() {
        ram = Array(repeating: 0, count: 64 * 1024)
        a = 0
        x = 0
        y = 0
        sp = 0xEF
        pc = 0xFFC0
        psw = 0x20
        portOut = [0, 0, 0, 0]
        portIn = [0, 0, 0, 0]
        timerEnabled = [false, false, false]
        timerTargets = [0, 0, 0]
        timerCounters = [0, 0, 0]
        timerOutputs = [0, 0, 0]
        timerDividers = [0, 0, 0]
        spcUploadAddr = 0x0200

    }
    func write(_ port: Int, data: UInt8) {
        let p = port & 3
        portIn[p] = data

        cpuToSpcToggle[p] ^= 0x80

        switch p {
        case 0:
            portOut[0] = data
            ram[Int(spcUploadAddr)] = data

        case 1:
            portOut[1] = data
            ram[Int(spcUploadAddr &+ 1)] = data
            spcUploadAddr &+= 2

        case 2:
            portOut[2] = data
            spcUploadAddr = (spcUploadAddr & 0xFF00) | UInt16(data)

        case 3:
            portOut[3] = data
            spcUploadAddr = (spcUploadAddr & 0x00FF) | (UInt16(data) << 8)

        default:
            break
        }
    }
    func read(_ port: Int) -> UInt8 {
        let p = port & 3

        let value = portOut[p] | spcToCpuToggle[p]

        print("CPU READ $214\(p) = \(String(format: "%02X", value))")

        return portOut[p]
    }

    func spcRead(_ addr: UInt16) -> UInt8 {
        if addr >= 0xFFC0 && (ram[0xF1] & 0x80) == 0 {
            return iplRom[Int(addr - 0xFFC0)]
        }
        return ram[Int(addr)]
    }

    func spcWriteToPort(_ index: Int, _ value: UInt8) {
        let p = index & 3

        portOut[p] = value

        spcToCpuToggle[p] ^= 0x40
    }

    func push(_ val: UInt8) {
        writeMem(0x0100 | UInt16(sp), data: val)
        sp &-= 1
    }

    func pull() -> UInt8 {
        sp &+= 1
        return readMem(0x0100 | UInt16(sp))
    }

    func readMem(_ addr: UInt16) -> UInt8 {
        if addr >= 0xFFC0 && (ram[0xF1] & 0x80) == 0 {
                return iplRom[Int(addr - 0xFFC0)]
        }
        switch addr {
        case 0x00F2:
            return dsp.index
        case 0x00F3:
            return dsp.readData()
        case 0x00F4:
            return portIn[0]
        case 0x00F5:
            return portIn[1]
        case 0x00F6:
            return portIn[2]
        case 0x00F7:
            return portIn[3]
        case 0x00FD:
            let val = timerOutputs[0]
            timerOutputs[0] = 0
            return val
        case 0x00FE:
            let val = timerOutputs[1]
            timerOutputs[1] = 0
            return val
        case 0x00FF:
            let val = timerOutputs[2]
            timerOutputs[2] = 0
            return val
        default:
            return ram[Int(addr)]
        }
    }

    func writeMem(_ addr: UInt16, data: UInt8) {
        if addr >= 0xFFC0 && (ram[0xF1] & 0x80) == 0 {
            print(String(format: "✅ IPL READ %04X = %02X", addr, iplRom[Int(addr - 0xFFC0)]))
        }

        ram[Int(addr)] = data
        switch addr {
        case 0x00F1:
            if (data & 0x10) != 0 {
                portIn[0] = 0
                portIn[1] = 0
            }
            if (data & 0x20) != 0 {
                portIn[2] = 0
                portIn[3] = 0
            }
            let t0 = (data & 0x01) != 0
            let t1 = (data & 0x02) != 0
            let t2 = (data & 0x04) != 0
            if !timerEnabled[0] && t0 {
                timerCounters[0] = 0
                timerDividers[0] = 0
            }
            if !timerEnabled[1] && t1 {
                timerCounters[1] = 0
                timerDividers[1] = 0
            }
            if !timerEnabled[2] && t2 {
                timerCounters[2] = 0
                timerDividers[2] = 0
            }
            timerEnabled[0] = t0
            timerEnabled[1] = t1
            timerEnabled[2] = t2

            psw = (psw & ~0x20) | 0x20

        case 0x00F2:
            dsp.setIndex(data)
        case 0x00F3:
            dsp.writeData(data)
        case 0x00F4:
            print("SPC WRITE $F4 =", String(format: "%02X", data))
            spcWriteToPort(0, data)

        case 0x00F5:
            print("SPC WRITE $F5 =", String(format: "%02X", data))
            spcWriteToPort(1, data)

        case 0x00F6:
            print("SPC WRITE $F6 =", String(format: "%02X", data))
            spcWriteToPort(2, data)

        case 0x00F7:
            portOut[3] = data
            spcWriteToPort(3, data)

            ram[0xF1] |= 0x80

            print("✅ SPC IPL DISABLED (NO FORCED JUMP)")

        case 0x00FA:
            timerTargets[0] = data
        case 0x00FB:
            timerTargets[1] = data

        case 0x00FC:
            timerTargets[2] = data
        default:
            break
        }
    }

    func readMem16(_ addr: UInt16) -> UInt16 {
        let low = readMem(addr)

        let high = readMem((addr & 0xFF00) | UInt16((addr & 0xFF) &+ 1))
        return UInt16(high) << 8 | UInt16(low)
    }

    func writeMem16(_ addr: UInt16, data: UInt16) {
        writeMem(addr, data: UInt8(data & 0xFF))
        writeMem((addr & 0xFF00) | UInt16((addr & 0xFF) &+ 1), data: UInt8(data >> 8))
    }

    func pushPC() {
        push(UInt8(pc >> 8))
        push(UInt8(pc & 0xFF))
    }

    func interrupt(vector: UInt16, isBRK: Bool) {

        let effectivePC = isBRK ? pc &+ 1 : pc
        push(UInt8(effectivePC >> 8))
        push(UInt8(effectivePC & 0xFF))

        let pswToPush = isBRK ? (psw | 0x08) : (psw & ~0x08)
        push(pswToPush)

        psw |= 0x04

        pc = readMem16(vector)
        cyclesRemaining = 8
    }

    func clock() {
        tickTimers()
        if cyclesRemaining > 0 {
            cyclesRemaining -= 1
            return
        }

        if pc == 0x0200 {
            print("✅ SPC EXECUTING UPLOADED PROGRAM AT $0200")
        }

        let opcode = readMem(pc)
        print(String(format: "SPC EXEC %04X  OPC=%02X  A=%02X X=%02X Y=%02X",
                     pc, opcode, a, x, y))
        pc &+= 1
        execute(opcode)

    }

    func run(cycles: Int) {
        guard cycles > 0 else { return }
        for _ in 0..<cycles {
            clock()
        }
    }

    func tickTimers() {
        for i in 0..<3 {
            if !timerEnabled[i] { continue }
            timerDividers[i] += 1
            let limit = (i == 2) ? 16 : 128
            if timerDividers[i] >= limit {
                timerDividers[i] = 0
                timerCounters[i] += 1
                let target = (timerTargets[i] == 0) ? 256 : Int(timerTargets[i])
                if timerCounters[i] >= target {
                    timerCounters[i] = 0
                    timerOutputs[i] = (timerOutputs[i] + 1) & 0x0F
                }
            }
        }
    }

    func branch(_ condition: Bool) {
        let offset = Int8(bitPattern: readMem(pc))
        pc &+= 1
        if condition {
            pc = UInt16(Int(pc) + Int(offset))
            cyclesRemaining = 4
        } else {
            cyclesRemaining = 2
        }
    }

    func compare(register: UInt8, operand: UInt8) {
        let result = register &- operand
        if register >= operand {
            psw |= 0x01
        } else {
            psw &= ~0x01
        }
        setZN(result)
    }

    func readOperand(mode: AddressingMode) -> (val: UInt8, addr: UInt16?, cycles: Int) {
        var addr: UInt16? = nil
        var cycles = 0
        var val: UInt8 = 0

        switch mode {
        case .immediate: val = readMem(pc); pc &+= 1; cycles = 2
        case .dp: let dp = readMem(pc); pc &+= 1; addr = UInt16(dp); val = readMem(addr!); cycles = 3
        case .dpX: let dp = readMem(pc); pc &+= 1; addr = UInt16(dp &+ x) & 0xFF; val = readMem(addr!); cycles = 4
        case .dpY: let dp = readMem(pc); pc &+= 1; addr = UInt16(dp &+ y) & 0xFF; val = readMem(addr!); cycles = 4
        case .absolute: let low = readMem(pc); let high = readMem(pc &+ 1); pc &+= 2; addr = UInt16(high) << 8 | UInt16(low); val = readMem(addr!); cycles = 4
        case .absoluteX: let low = readMem(pc); let high = readMem(pc &+ 1); pc &+= 2; let base = UInt16(high) << 8 | UInt16(low); addr = base &+ UInt16(x); val = readMem(addr!); cycles = 5
        case .absoluteY: let low = readMem(pc); let high = readMem(pc &+ 1); pc &+= 2; let base = UInt16(high) << 8 | UInt16(low); addr = base &+ UInt16(y); val = readMem(addr!); cycles = 5
        case .indirectX: let dp = readMem(pc); pc &+= 1; let ptrAddr = UInt16(dp &+ x) & 0xFF; addr = readMem16(ptrAddr); val = readMem(addr!); cycles = 6
        case .indirectY: let dp = readMem(pc); pc &+= 1; let baseAddr = readMem16(UInt16(dp)); addr = baseAddr &+ UInt16(y); val = readMem(addr!); cycles = 6
        case .indirectAbsX: let low = readMem(pc); let high = readMem(pc &+ 1); pc &+= 2; let basePtr = UInt16(high) << 8 | UInt16(low); let ptrAddr = basePtr &+ UInt16(x); addr = readMem16(ptrAddr); cycles = 6
        case .indirectAbs: let low = readMem(pc); let high = readMem(pc &+ 1); pc &+= 2; let ptrAddr = UInt16(high) << 8 | UInt16(low); addr = readMem16(ptrAddr); cycles = 5
        case .indirectZeroPage: addr = UInt16(x); val = readMem(addr!); cycles = 3
        case .indirectDp: let dp = readMem(pc); pc &+= 1; addr = readMem16(UInt16(dp)); val = readMem(addr!); cycles = 5
        }
        return (val, addr, cycles)
    }

    func writeOperand(mode: AddressingMode, val: UInt8) -> Int {
        var addr: UInt16? = nil
        var cycles = 0

        switch mode {
        case .dp: let dp = readMem(pc); pc &+= 1; addr = UInt16(dp); cycles = 4
        case .dpX: let dp = readMem(pc); pc &+= 1; addr = UInt16(dp &+ x) & 0xFF; cycles = 5
        case .dpY: let dp = readMem(pc); pc &+= 1; addr = UInt16(dp &+ y) & 0xFF; cycles = 5
        case .absolute: let low = readMem(pc); let high = readMem(pc &+ 1); pc &+= 2; addr = UInt16(high) << 8 | UInt16(low); cycles = 5
        case .absoluteX: let low = readMem(pc); let high = readMem(pc &+ 1); pc &+= 2; let base = UInt16(high) << 8 | UInt16(low); addr = base &+ UInt16(x); cycles = 6
        case .absoluteY: let low = readMem(pc); let high = readMem(pc &+ 1); pc &+= 2; let base = UInt16(high) << 8 | UInt16(low); addr = base &+ UInt16(y); cycles = 6
        case .indirectX: let dp = readMem(pc); pc &+= 1; let ptrAddr = UInt16(dp &+ x) & 0xFF; addr = readMem16(ptrAddr); cycles = 6
        case .indirectY: let dp = readMem(pc); pc &+= 1; let baseAddr = readMem16(UInt16(dp)); addr = baseAddr &+ UInt16(y); cycles = 6
        default: fatalError("Unsupported addressing mode for write: \(mode)")
        }
        writeMem(addr!, data: val)
        return cycles
    }

    func setFlags(a: UInt8, b: UInt8, result: UInt8, isADC: Bool) {
        if isADC {
            let sum = UInt16(a) + UInt16(b) + UInt16(psw & 0x01)
            if sum > 0xFF { psw |= 0x01 } else { psw &= ~0x01 }
        } else {
            let borrow = (psw & 0x01) == 0
            let comparison = UInt16(a) >= UInt16(b) + (borrow ? 1 : 0)
            if comparison { psw |= 0x01 } else { psw &= ~0x01 }
        }
        let opB: UInt8 = isADC ? b : (~b &+ 1)
        if ((a ^ opB) & 0x80) == 0 && ((a ^ result) & 0x80) != 0 {
            psw |= 0x40
        } else {
            psw &= ~0x40
        }
    }

    func adc(operand: UInt8) {
        let carry = psw & 0x01
        let sum = a &+ operand &+ carry
        setFlags(a: a, b: operand, result: sum, isADC: true)
        a = sum
        setZN(a)
    }

    func sbc(operand: UInt8) {
        let carryBit = (psw & 0x01)
        let result = a &- operand &- (1 &- carryBit)
        setFlags(a: a, b: operand, result: result, isADC: false)
        a = result
        setZN(a)
    }

    func andLogic(operand: UInt8) { a = a & operand; setZN(a) }
    func orLogic(operand: UInt8) { a = a | operand; setZN(a) }
    func eorLogic(operand: UInt8) { a = a ^ operand; setZN(a) }

    func incDecMem(addr: UInt16, increment: Bool) {
        var val = readMem(addr)
        if increment { val &+= 1 } else { val &-= 1 }
        writeMem(addr, data: val)
        setZN(val)
    }

    func shiftRotate(addr: UInt16?, mode: ShiftRotateMode) {
        var val: UInt8
        if let addr = addr { val = readMem(addr) } else { val = a }
        let oldCarry = psw & 0x01
        var newCarry: UInt8 = 0

        switch mode {
        case .asl: newCarry = (val & 0x80) >> 7; val = val << 1
        case .lsr: newCarry = val & 0x01; val = val >> 1
        case .rol: newCarry = (val & 0x80) >> 7; val = (val << 1) | oldCarry
        case .ror: newCarry = val & 0x01; val = (val >> 1) | (oldCarry << 7)
        }

        if newCarry != 0 { psw |= 0x01 } else { psw &= ~0x01 }
        if let addr = addr { writeMem(addr, data: val) } else { a = val }
        setZN(val)
    }

    func tsetTclr(addr: UInt16, mask: UInt8, set: Bool) {
        var val = readMem(addr)
        setZN(val & mask)
        if set { val = val | mask } else { val = val & ~mask }
        writeMem(addr, data: val)
    }

    func bitBranch(opcode: UInt8, set: Bool) {
        let bit = (opcode & 0xF0) >> 4
        let dp = readMem(pc); pc &+= 1
        let offset = Int8(bitPattern: readMem(pc)); pc &+= 1

        let addr = UInt16(dp)
        let val = readMem(addr)
        let bitIsSet = (val & (1 << bit)) != 0
        let condition = set ? bitIsSet : !bitIsSet

        if condition { pc = pc &+ UInt16(bitPattern: Int16(offset)); cyclesRemaining = 8 } else { cyclesRemaining = 6 }
    }

    func setClearBit(opcode: UInt8, set: Bool) {
        let bit = (opcode & 0xF0) >> 4
        let dp = readMem(pc); pc &+= 1

        let addr = UInt16(dp)
        var val = readMem(addr)
        let mask: UInt8 = 1 << bit

        if set { val |= mask } else { val &= ~mask }
        writeMem(addr, data: val)
        cyclesRemaining = 5
    }

    func decimalAdjust(isDAA: Bool) {
        var a16 = UInt16(a); var carry = (psw & 0x01) != 0
        if (psw & 0x08) != 0 {
            if isDAA {
                if (a & 0x0F) > 0x09 || (psw & 0x01) == 0 { a16 &+= 0x06 }
                if a16 > 0x9F || carry { a16 &+= 0x60; carry = true }
            } else {
                if (a & 0x0F) > 0x09 || (psw & 0x01) == 0 { a16 &-= 0x06 }
                if (psw & 0x80) != 0 || carry { a16 &-= 0x60 }
            }
        }
        if carry { psw |= 0x01 } else { psw &= ~0x01 }
        a = UInt8(a16 & 0xFF); setZN(a); cyclesRemaining = 3
    }

    func execute(_ opcode: UInt8) {
        switch opcode {
        case 0x00:
            print("⚠️ SPC EXEC BRK AT", String(format:"%04X", pc-1))
            cyclesRemaining = 2
            return

        case 0xCD:
            let val = readMem(pc)
            x = val
            setZN(x)
            pc = pc &+ 1
            cyclesRemaining = 2
        case 0x8F:
            let val = readMem(pc)
            let addr = readMem(pc &+ 1)

            writeMem(0x0000 | UInt16(addr), data: val)

            pc = pc &+ 2
            cyclesRemaining = 5

        case 0x78:
            let addr = readMem(pc)
            let val = readMem(0x0000 | UInt16(addr))
            x = val
            setZN(x)
            pc = pc &+ 1
            cyclesRemaining = 4
        case 0x2F:
            let offset = Int8(bitPattern: readMem(pc))
            pc = pc &+ 1

            if (psw & 0x02) == 0 {
                let signedPC = Int32(pc)
                let signedOff = Int32(offset)
                let newPC = signedPC &+ signedOff
                pc = UInt16(truncatingIfNeeded: newPC)
                cyclesRemaining = 4
            } else {
                cyclesRemaining = 2
            }

        case 0xF0:
            cyclesRemaining = 2
        case 0x80:
            a = portIn[0]
            setZN(a)
            cyclesRemaining = 2
        case 0xE4:
            let addr = readMem(pc)
            let val = readMem(0x0000 | UInt16(addr))
            a = val
            setZN(a)
            pc = pc &+ 1
            cyclesRemaining = 3
        case 0xF4:
            let addr = readMem(pc)
            a = readMem(0x0000 | UInt16(addr))
            setZN(a)
            pc = pc &+ 1
            cyclesRemaining = 3
        case 0xF8:
            let addr = readMem(pc)
            x = readMem(0x0000 | UInt16(addr))
            setZN(x)
            pc = pc &+ 1
            cyclesRemaining = 3
        case 0xFA:
            let addr = readMem(0x0000 | UInt16(readMem(pc)))
            let dest = readMem(0x0000 | UInt16(readMem(pc &+ 1)))
            writeMem(0x0000 | UInt16(dest), data: readMem(0x0000 | UInt16(addr)))
            pc = pc &+ 2
            cyclesRemaining = 5
        case 0x8D:
            let val = readMem(pc)
            y = val
            setZN(y)
            pc = pc &+ 1
            cyclesRemaining = 2
        case 0xAA:
            let addr = UInt16(readMem(pc)) | (UInt16(readMem(pc &+ 1)) << 8)
            let val = readMem(addr)
            writeMem(addr, data: val)
            pc = pc &+ 2
            cyclesRemaining = 4
        case 0xE8:
            a = readMem(pc)
            setZN(a)
            pc = pc &+ 1
            cyclesRemaining = 2
        case 0xBA:
            let addr = readMem(pc)
            y = readMem(0x0000 | UInt16(addr))
            setZN(y)
            pc = pc &+ 1
            cyclesRemaining = 3
        case 0xD0:
            let offset = Int8(bitPattern: readMem(pc))
            pc = pc &+ 1

            if (psw & 0x02) == 0 {
                let signedPC = Int32(pc)
                let signedOff = Int32(offset)
                let newPC = signedPC &+ signedOff
                pc = UInt16(truncatingIfNeeded: newPC)
                cyclesRemaining = 4
            } else {
                cyclesRemaining = 2
            }

        case 0xC4:
            let addr = readMem(pc)
            writeMem(0x0000 | UInt16(addr), data: a)
            pc = pc &+ 1
            cyclesRemaining = 4

        case 0xBF:
            let src = UInt16(readMem(pc))
            let dst = UInt16(readMem(pc &+ 1))
            pc &+= 2

            let lo = readMem(src)
            let hi = readMem(src &+ 1)

            writeMem(dst, data: lo)
            writeMem(dst &+ 1, data: hi)

            cyclesRemaining = 5

        case 0xFF:
            let dpDest = UInt16(readMem(pc))
            let dpSrc  = UInt16(readMem(pc &+ 1))
            pc &+= 2

            let lo = readMem(dpSrc)
            let hi = readMem(dpSrc &+ 1)

            let dest = dpDest &+ UInt16(x)
            writeMem(dest,       data: lo)
            writeMem(dest &+ 1,  data: hi)

            cyclesRemaining = 5

        case 0x02: psw |= 0x01; cyclesRemaining = 2
        case 0x12: psw &= ~0x08; cyclesRemaining = 2
        case 0x22: psw |= 0x40; cyclesRemaining = 2
        case 0x32: psw &= ~0x40; cyclesRemaining = 2
        case 0x52: psw |= 0x04; cyclesRemaining = 2
        case 0x72: psw &= ~0x04; cyclesRemaining = 2

        case 0x0D, 0x1D, 0x2D, 0x3D: setClearBit(opcode: opcode, set: true)
        case 0x4D, 0x5D, 0x6D, 0x7D: setClearBit(opcode: opcode, set: false)

        case 0x03, 0x13, 0x23, 0x33, 0x43, 0x53, 0x63, 0x73: bitBranch(opcode: opcode, set: false)
        case 0x83, 0x93, 0xA3, 0xB3, 0xC3, 0xD3, 0xE3, 0xF3: bitBranch(opcode: opcode, set: true)

        case 0x20: push(x); cyclesRemaining = 4
        case 0x40: push(y); cyclesRemaining = 4
        case 0x5C: x = pull(); setZN(x); cyclesRemaining = 5
        case 0x7C: y = pull(); setZN(y); cyclesRemaining = 5
        case 0x68: push(a); cyclesRemaining = 4
        case 0x28: a = pull(); setZN(a); cyclesRemaining = 5

        case 0xAE: psw = pull() | 0x20; cyclesRemaining = 5

        case 0x8A: a = (a >> 4) | (a << 4); setZN(a); cyclesRemaining = 2
        case 0xF9: decimalAdjust(isDAA: true)

        default:

            if opcode == 0x1A { a &+= 1; setZN(a); cyclesRemaining = 2 }
            else if opcode == 0x3A { x &+= 1; setZN(x); cyclesRemaining = 2 }
            else if opcode == 0x9A { y &+= 1; setZN(y); cyclesRemaining = 2 }
            else if opcode == 0xEA { a &-= 1; setZN(a); cyclesRemaining = 2 }
            else if opcode == 0x9C { x &-= 1; setZN(x); cyclesRemaining = 2 }
            else if opcode == 0xCA { y &-= 1; setZN(y); cyclesRemaining = 2 }

            cyclesRemaining = 2
        }
    }

    func setZN(_ val: UInt8) {
        if val == 0 { psw |= 0x02 } else { psw &= ~0x02 }
        if (val & 0x80) != 0 { psw |= 0x80 } else { psw &= ~0x80 }
    }
}
