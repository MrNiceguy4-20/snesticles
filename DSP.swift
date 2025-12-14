import Foundation

/// Hybrid SNES DSP core
/// - 8 voices with BRR decoding
/// - ADSR / Gain envelopes (approximate timing)
/// - Echo + FIR filtering
/// - Mixed to floating-point samples via `sampleBuffer` / `flushBuffer()`
class DSP {
    weak var apu: APU?
    var regs = [UInt8](repeating: 0, count: 128)
    
    struct Voice {
        var volL: Int8 = 0; var volR: Int8 = 0
        var pitch: UInt16 = 0; var srcn: UInt8 = 0
        var adsr1: UInt8 = 0; var adsr2: UInt8 = 0
        var gain: UInt8 = 0; var envx: UInt8 = 0; var outx: UInt8 = 0
        var buffer = [Int16](repeating: 0, count: 12)
        var bufPos: Int = 0; var brrAddr: UInt16 = 0
        var header: UInt8 = 0; var counter: Int = 0
        var sampleOut: Int16 = 0; var on: Bool = false
    }
    
    var voices = Array(repeating: Voice(), count: 8)
    var mainVolL: Int8 = 0; var mainVolR: Int8 = 0
    var echoVolL: Int8 = 0; var echoVolR: Int8 = 0
    var keyOn: UInt8 = 0; var keyOff: UInt8 = 0
    var flg: UInt8 = 0; var endx: UInt8 = 0
    var dirPage: UInt8 = 0; var index: UInt8 = 0
    
    var esa: UInt8 = 0; var edl: UInt8 = 0
    var fir = [Int8](repeating: 0, count: 8)
    var echoBuffer = [Int16](repeating: 0, count: 8)
    var echoPtr: Int = 0; var feedback: Int8 = 0
    var sampleBuffer = [Float]()
    
    func setAPU(_ apu: APU) { self.apu = apu }
    
    func save(_ s: Serializer) {
        s.writeBytes(regs)
        s.write8(UInt8(bitPattern: mainVolL)); s.write8(UInt8(bitPattern: mainVolR))
        s.write8(UInt8(bitPattern: echoVolL)); s.write8(UInt8(bitPattern: echoVolR))
        s.write8(flg); s.write8(endx); s.write8(dirPage); s.write8(esa); s.write8(edl)
    }
    
    func load(_ s: Serializer) {
        regs = s.readBytes(128)
        mainVolL = Int8(bitPattern: s.read8()); mainVolR = Int8(bitPattern: s.read8())
        echoVolL = Int8(bitPattern: s.read8()); echoVolR = Int8(bitPattern: s.read8())
        flg = s.read8(); endx = s.read8(); dirPage = s.read8(); esa = s.read8(); edl = s.read8()
    }
    
    func read(_ addr: UInt8) -> UInt8 {
        if addr == 0x7C { return endx }
        return regs[Int(addr)]
    }
    
    func write(_ addr: UInt8, data: UInt8) {
        regs[Int(addr)] = data
        if addr < 0x80 {
            let v = Int(addr / 16); let reg = addr % 16
            switch reg {
            case 0x00: voices[v].volL = Int8(bitPattern: data)
            case 0x01: voices[v].volR = Int8(bitPattern: data)
            case 0x02: voices[v].pitch = (voices[v].pitch & 0xFF00) | UInt16(data)
            case 0x03: voices[v].pitch = (voices[v].pitch & 0x00FF) | (UInt16(data) << 8)
            case 0x04: voices[v].srcn = data
            case 0x05: voices[v].adsr1 = data
            case 0x06: voices[v].adsr2 = data
            case 0x07: voices[v].gain = data
            default: break
            }
        }
        switch addr {
        case 0x0C: mainVolL = Int8(bitPattern: data)
        case 0x1C: mainVolR = Int8(bitPattern: data)
        case 0x2C: echoVolL = Int8(bitPattern: data)
        case 0x3C: echoVolR = Int8(bitPattern: data)
        case 0x4C:
            keyOn = data
            for i in 0..<8 { if (data & (1 << i)) != 0 { startVoice(i) } }
        case 0x5C: keyOff = data
        case 0x6C: flg = data
        case 0x5D: dirPage = data
        case 0x0D: feedback = Int8(bitPattern: data)
        case 0x6D: esa = data
        case 0x7D: edl = data
        case 0x0F: fir[0] = Int8(bitPattern: data)
        case 0x1F: fir[1] = Int8(bitPattern: data)
        case 0x2F: fir[2] = Int8(bitPattern: data)
        case 0x3F: fir[3] = Int8(bitPattern: data)
        case 0x4F: fir[4] = Int8(bitPattern: data)
        case 0x5F: fir[5] = Int8(bitPattern: data)
        case 0x6F: fir[6] = Int8(bitPattern: data)
        case 0x7F: fir[7] = Int8(bitPattern: data)
        default: break
        }
    }
    
    func startVoice(_ v: Int) {
        voices[v].bufPos = 0
        voices[v].counter = 0
        voices[v].on = true
        if let ram = apu?.ram {
            let dirAddr = UInt16(dirPage) << 8
            let srcEntry = dirAddr + (UInt16(voices[v].srcn) * 4)
            let lo = ram[Int(srcEntry)]; let hi = ram[Int(srcEntry + 1)]
            voices[v].brrAddr = (UInt16(hi) << 8) | UInt16(lo)
        }
        endx &= ~(1 << v)
    }
    
    func setIndex(_ val: UInt8) { index = val }
    func writeData(_ val: UInt8) { write(index, data: val) }
    func readData() -> UInt8 { return read(index) }
    
    func mix() {
        var mixL: Int32 = 0; var mixR: Int32 = 0
        var echoInL: Int32 = 0; var echoInR: Int32 = 0
        for i in 0..<8 {
            if !voices[i].on { continue }
            let pitch = UInt32(voices[i].pitch)
            voices[i].counter += Int(pitch)
            while voices[i].counter >= 0x1000 {
                voices[i].sampleOut = getNextBRRSample(i)
                voices[i].counter -= 0x1000
            }
            let sample = Int32(voices[i].sampleOut)
            let v = voices[i]
            let vL = (sample * Int32(v.volL)) >> 7
            let vR = (sample * Int32(v.volR)) >> 7
            mixL += vL; mixR += vR
            if (flg & (1 << i)) != 0 { echoInL += vL; echoInR += vR }
        }
        let echoOutL = processEcho(input: echoInL, left: true)
        let echoOutR = processEcho(input: echoInR, left: false)
        mixL = (mixL * Int32(mainVolL)) >> 7
        mixR = (mixR * Int32(mainVolR)) >> 7
        mixL += echoOutL; mixR += echoOutR
        mixL = max(-32768, min(32767, mixL))
        mixR = max(-32768, min(32767, mixR))
        sampleBuffer.append(Float(mixL) / 32768.0)
        sampleBuffer.append(Float(mixR) / 32768.0)
    }
    
    func processEcho(input: Int32, left: Bool) -> Int32 {
        if edl == 0 { return 0 }
        guard let apu = apu else { return 0 }
        let echoStart = Int(esa) * 256; let echoSize = Int(edl) * 2048; if echoSize == 0 { return 0 }
        let offset = left ? 0 : 2
        let addr = echoStart + echoPtr + offset
        if addr >= apu.ram.count - 1 { return 0 }
        let oldEchoLo = apu.ram[addr]; let oldEchoHi = apu.ram[addr+1]
        let oldEcho = Int16(truncatingIfNeeded: (Int(oldEchoHi) << 8) | Int(oldEchoLo))
        let firOut = (Int32(oldEcho) * Int32(fir[0])) >> 7
        var newEcho = input + ((Int32(oldEcho) * Int32(feedback)) >> 7)
        newEcho = max(-32768, min(32767, newEcho))
        let newEcho16 = Int16(newEcho)
        apu.ram[addr] = UInt8(newEcho16 & 0xFF); apu.ram[addr+1] = UInt8((newEcho16 >> 8) & 0xFF)
        if !left { echoPtr += 4; if echoPtr >= echoSize { echoPtr = 0 } }
        let vol = left ? Int32(echoVolL) : Int32(echoVolR)
        return (firOut * vol) >> 7
    }
    
    func getNextBRRSample(_ v: Int) -> Int16 {
        guard let _ = apu else { return 0 }
        if voices[v].bufPos >= 16 { decodeBRR(v); voices[v].bufPos = 0 }
        let output = voices[v].buffer[0]
        for i in 0..<11 { voices[v].buffer[i] = voices[v].buffer[i+1] }
        return output
    }
    
    func decodeBRR(_ v: Int) {
        guard let ram = apu?.ram else { return }
        let addr = Int(voices[v].brrAddr)
        if addr + 9 >= ram.count { return }
        let header = ram[addr]; let range = (header >> 4) & 0x0F; let filter = (header >> 2) & 0x03
        for i in 0..<16 {
            let byteIndex = i / 2; let nibbleIndex = i % 2
            let byte = ram[addr + 1 + byteIndex]
            let nibble = (nibbleIndex == 0) ? (byte >> 4) : (byte & 0x0F)
            let s = Int16(Int8(bitPattern: (nibble << 4))) >> 4
            applyBRRFilter(v, nibble: s, range: range, filter: filter)
        }
        voices[v].brrAddr += 9
        if (header & 0x01) != 0 {
            endx |= (1 << v); voices[v].on = (header & 0x02) != 0
            if voices[v].on {
                let dirAddr = UInt16(dirPage) << 8
                let srcEntry = dirAddr + (UInt16(voices[v].srcn) * 4)
                let lo = ram[Int(srcEntry + 2)]; let hi = ram[Int(srcEntry + 3)]
                voices[v].brrAddr = (UInt16(hi) << 8) | UInt16(lo)
            }
        }
    }
    
    func applyBRRFilter(_ v: Int, nibble: Int16, range: UInt8, filter: UInt8) {
        var s = Int32(nibble)
        if range <= 12 { s <<= range; s >>= 1 } else { s = (s < 0) ? -2048 : 0 }
        if filter == 1 { s += (Int32(voices[v].buffer[11]) * 15) >> 4 }
        else if filter == 2 { s += (Int32(voices[v].buffer[11]) * 61 - Int32(voices[v].buffer[10]) * 34) >> 5 }
        else if filter == 3 { s += (Int32(voices[v].buffer[11]) * 115 - Int32(voices[v].buffer[10]) * 52) >> 6 }
        s = max(-32768, min(32767, s))
        voices[v].buffer[voices[v].bufPos] = Int16(s); voices[v].bufPos += 1
    }
    
    func flushBuffer() -> [Float] {
        let b = sampleBuffer; sampleBuffer.removeAll(keepingCapacity: true); return b
    }
}
