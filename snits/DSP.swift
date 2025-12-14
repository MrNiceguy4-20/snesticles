//
//  DSP.swift
//  snits
//
//  Created by kevin on 2025-12-05.
//

import Foundation

final class DSP {
    weak var apu: APU?
    
    // MARK: - Registers & State
    private var regs = [UInt8](repeating: 0, count: 128)
    
    private struct Voice {
        var volL: Int8 = 0, volR: Int8 = 0
        var pitch: UInt16 = 0
        var srcn: UInt8 = 0
        var adsr1: UInt8 = 0, adsr2: UInt8 = 0
        var gain: UInt8 = 0
        var envx: UInt8 = 0, outx: UInt8 = 0
        
        // Playback State
        var brrAddr: UInt16 = 0
        var brrOffset = 0
        var brrBuffer = [Int16](repeating: 0, count: 16)
        var prev1: Int16 = 0, prev2: Int16 = 0
        var loop = false
        
        // Envelope State
        var env: Int32 = 0
        var envMode = 0  // 0=off, 1=attack, 2=decay, 3=sustain, 4=release, 5=direct
        var envRate = 0
        var envCounter = 0
        var keyOnDelay = 0
    }
    
    private var voices = Array(repeating: Voice(), count: 8)
    
    // Master Controls
    private var mainVolL: Int8 = 0, mainVolR: Int8 = 0
    private var echoVolL: Int8 = 0, echoVolR: Int8 = 0
    private var flg: UInt8 = 0
    private var endx: UInt8 = 0
    
    // Echo / FIR
    private var dirPage: UInt8 = 0
    private var esa: UInt8 = 0
    private var edl: UInt8 = 0
    private var efb: Int8 = 0
    private var firCoeff = [Int8](repeating: 0, count: 8)
    
    private var echoBufferOffset: Int { Int(esa) << 8 }
    private var echoBufferSize: Int { max(4, Int(edl) * 2048) }
    private var echoPtr = 0
    private var echoEnable = false
    
    // Noise Generator
    private var noiseRate = 0
    private var noiseCounter = 0
    private var noiseLFSR: UInt16 = 0x4000
    
    // Output
    private var sampleBuffer = [Float]()
    
    init() { reset() }
    
    func reset() {
        regs = [UInt8](repeating: 0, count: 128)
        voices = Array(repeating: Voice(), count: 8)
        mainVolL = 0; mainVolR = 0
        echoVolL = 0; echoVolR = 0
        flg = 0; endx = 0
        dirPage = 0; esa = 0; edl = 0; efb = 0
        firCoeff = [0,0,0,0,0,0,0,0]
        sampleBuffer.removeAll()
        noiseLFSR = 0x4000
        echoPtr = 0
        echoEnable = false
    }
    
    // MARK: - Register I/O
    
    func read(_ addr: UInt8) -> UInt8 {
        return regs[Int(addr)]
    }
    
    func write(_ addr: UInt8, _ value: UInt8) {
        regs[Int(addr)] = value
        
        let port = addr & 0x7F // Mask to 7-bit to handle register mirroring
        let voiceIdx = Int(addr >> 4)
        let regIdx = Int(addr & 0x0F)
        
        // Per-Voice Registers ($00-$7F)
        if voiceIdx < 8 {
            switch regIdx {
            case 0x00: voices[voiceIdx].volL = Int8(bitPattern: value)
            case 0x01: voices[voiceIdx].volR = Int8(bitPattern: value)
            case 0x02: voices[voiceIdx].pitch = (voices[voiceIdx].pitch & 0xFF00) | UInt16(value)
            case 0x03: voices[voiceIdx].pitch = (voices[voiceIdx].pitch & 0x00FF) | (UInt16(value) << 8)
            case 0x04: voices[voiceIdx].srcn = value
            case 0x05: voices[voiceIdx].adsr1 = value
            case 0x06: voices[voiceIdx].adsr2 = value
            case 0x07: voices[voiceIdx].gain = value
            default: break
            }
            return
        }
        
        // Global Registers
        switch port {
        case 0x0C: mainVolL = Int8(bitPattern: value)
        case 0x1C: mainVolR = Int8(bitPattern: value)
        case 0x2C: echoVolL = Int8(bitPattern: value)
        case 0x3C: echoVolR = Int8(bitPattern: value)
        case 0x4C: // Key On
            for i in 0..<8 {
                if (value & (1 << i)) != 0 {
                    keyOn(i)
                }
            }
        case 0x5C: // Key Off
            for i in 0..<8 {
                if (value & (1 << i)) != 0 {
                    keyOff(i)
                }
            }
        case 0x6C: flg = value
        case 0x7C: endx = 0 // Write clears?
        case 0x0D: efb = Int8(bitPattern: value)
        case 0x2D: // Pitch Mod (ignored in simple core)
            break
        case 0x3D: noiseRate = Int(value & 0x1F)
        case 0x4D: esa = value
        case 0x5D: edl = value
        case 0x6D: dirPage = value
        case 0x7D: break
            
        // FIR Coefficients ($0F, $1F... $7F)
        case 0x0F: firCoeff[0] = Int8(bitPattern: value)
        case 0x1F: firCoeff[1] = Int8(bitPattern: value)
        case 0x2F: firCoeff[2] = Int8(bitPattern: value)
        case 0x3F: firCoeff[3] = Int8(bitPattern: value)
        case 0x4F: firCoeff[4] = Int8(bitPattern: value)
        case 0x5F: firCoeff[5] = Int8(bitPattern: value)
        case 0x6F: firCoeff[6] = Int8(bitPattern: value)
        case 0x7F: firCoeff[7] = Int8(bitPattern: value)
            
        default: break
        }
        
        echoEnable = (flg & 0x20) == 0 && edl > 0
    }
    
    // MARK: - Key Control
    
    private func keyOn(_ v: Int) {
        voices[v].keyOnDelay = 5
        voices[v].env = 0
        voices[v].envMode = 1 // Attack
        voices[v].prev1 = 0
        voices[v].prev2 = 0
        
        // Load DIR pointer
        if let apu = apu {
            let dirBase = UInt16(dirPage) << 8
            let srcOffset = UInt16(voices[v].srcn) * 4
            let addr = dirBase &+ srcOffset
            
            let lo = apu.ram[Int(addr)]
            let hi = apu.ram[Int(addr + 1)]
            voices[v].brrAddr = (UInt16(hi) << 8) | UInt16(lo)
            voices[v].brrOffset = 0
        }
    }
    
    private func keyOff(_ v: Int) {
        voices[v].envMode = 4 // Release
    }
    
    // MARK: - Core Audio Generation
    
    func clock() {
        // Envelopes
        for i in 0..<8 {
            updateEnvelope(i)
        }
        
        // Mixing
        var mainL: Int32 = 0
        var mainR: Int32 = 0
        var echoL: Int32 = 0
        var echoR: Int32 = 0
        
        for v in 0..<8 {
            let voice = voices[v]
            
            // Optimization: Skip silent voices
            if voice.envMode == 0 { continue }
            
            // Get raw sample (Decode BRR or Noise)
            var sample: Int32 = 0
            if (flg & (1 << 3)) != 0 && (flg & (1 << v)) != 0 {
                 sample = Int32(noiseSample())
            } else {
                 sample = Int32(decodeBRR(v))
            }
            
            // Apply Envelope / Gain
            // SNES env is 11-bit ($0-$7FF). sample is 16-bit.
            // Result 27-bit? We scale down.
            let envVal = voice.env >> 4 // Scale to ~7 bits
            sample = (sample * envVal) >> 7
            
            // Update OUTX (envelope height)
            voices[v].envx = UInt8(min(255, max(0, voice.env >> 3)))
            
            // Stereo Panning & Mixing
            let vL = Int32(voice.volL)
            let vR = Int32(voice.volR)
            
            mainL += (sample * vL) >> 7
            mainR += (sample * vR) >> 7
            
            // Echo Mixing
            if (flg & 0x20) == 0 && (regs[0x4D] & (1 << v)) != 0 {
                echoL += (sample * vL) >> 7
                echoR += (sample * vR) >> 7
            }
        }
        
        // Echo Processing (Simplified FIR)
        if echoEnable {
            let hist = echoRead()
            // FIR filter roughly: mix history with current echo input
            let feedback = (Int32(hist.0) * Int32(efb)) >> 7
            echoL += feedback
            echoR += feedback
            echoWrite(l: Int16(truncatingIfNeeded: echoL), r: Int16(truncatingIfNeeded: echoR))
        }
        
        // Master Volume
        mainL = (mainL * Int32(mainVolL)) >> 7
        mainR = (mainR * Int32(mainVolR)) >> 7
        
        // Clamp 16-bit
        mainL = max(-32768, min(32767, mainL))
        mainR = max(-32768, min(32767, mainR))
        
        // Output Float
        sampleBuffer.append(Float(mainL) / 32768.0)
        sampleBuffer.append(Float(mainR) / 32768.0)
    }
    
    // MARK: - Envelope Logic
    
    private func updateEnvelope(_ v: Int) {
        var voice = voices[v]
        
        // Handle Key On Delay
        if voice.keyOnDelay > 0 {
            voice.keyOnDelay -= 1
            if voice.keyOnDelay == 0 {
                // Actually start envelope
                voice.env = 0
                voice.envMode = 1
            }
            voices[v] = voice
            return
        }
        
        // ADSR / GAIN Logic
        let isADSR = (voice.adsr1 & 0x80) != 0
        
        if isADSR {
            switch voice.envMode {
            case 1: // Attack
                let rate = (voice.adsr1 & 0x0F) * 2 + 1
                voice.env += 32 // Simplified rate
                if voice.env >= 0x7FF {
                    voice.env = 0x7FF
                    voice.envMode = 2 // Decay
                }
            case 2: // Decay
                voice.env -= 8 // Simplified rate
                let sustainLevel = Int32(voice.adsr2 >> 5) * 0x100
                if voice.env <= sustainLevel {
                    voice.env = sustainLevel
                    voice.envMode = 3 // Sustain
                }
            case 3: // Sustain
                // Exponential decay
                voice.env -= 4
                if voice.env < 0 { voice.env = 0 }
            case 4: // Release
                voice.env -= 8
                if voice.env <= 0 {
                    voice.env = 0
                    voice.envMode = 0 // Off
                }
            default: break
            }
        } else {
            // GAIN Mode (Direct)
            if (voice.gain & 0x80) == 0 {
                 // Direct setting
                 let target = Int32(voice.gain & 0x7F) * 16
                 if voice.env < target { voice.env += 32 }
                 else if voice.env > target { voice.env -= 32 }
            } else {
                // Modes (Bent line, Exponential, etc) - treat as direct for now
                 voice.env = Int32(voice.gain & 0x7F) * 16
            }
        }
        
        voices[v] = voice
    }
    
    // MARK: - BRR Decoding
    
    private func decodeBRR(_ v: Int) -> Int16 {
        var voice = voices[v]
        guard let apu = apu else { return 0 }
        
        // Need to decode a block?
        if voice.brrOffset == 0 {
            // Read Header
            let header = apu.ram[Int(voice.brrAddr)]
            voice.brrAddr &+= 1
            
            let range = (header >> 4)
            let filter = (header >> 2) & 0x03
            voice.loop = (header & 0x02) != 0
            let end = (header & 0x01) != 0
            if end { voice.loop = true; endx |= (1 << v) }
            
            // Shift history
            for i in 0..<16 {
                if i < 14 {
                    voice.brrBuffer[i] = voice.brrBuffer[i+2]
                }
            }
            
            // Decode 16 samples (4 bytes = 8 nibbles)
            // Note: Proper BRR block is 9 bytes (1 header + 8 data)
            for i in 0..<8 {
                let byte = apu.ram[Int(voice.brrAddr)]
                voice.brrAddr &+= 1
                
                // Hi nibble
                let ni1 = Int32(Int8(bitPattern: byte & 0xF0)) >> 4
                let sample1 = applyRange(ni1, range: Int(range))
                voice.brrBuffer[i*2] = applyFilter(sample1, filter: Int(filter), p1: voice.prev1, p2: voice.prev2)
                voice.prev2 = voice.prev1
                voice.prev1 = voice.brrBuffer[i*2]
                
                // Lo nibble
                let ni2 = Int32(Int8(bitPattern: (byte & 0x0F) << 4)) >> 4 // Sign extend
                let sample2 = applyRange(ni2, range: Int(range))
                voice.brrBuffer[i*2+1] = applyFilter(sample2, filter: Int(filter), p1: voice.prev1, p2: voice.prev2)
                voice.prev2 = voice.prev1
                voice.prev1 = voice.brrBuffer[i*2+1]
            }
            
            voice.brrOffset = 16
        }
        
        // Output current sample
        let sampleIndex = 16 - voice.brrOffset
        let output = voice.brrBuffer[sampleIndex]
        
        voice.brrOffset -= 1
        
        // Handle Loop
        if voice.brrOffset == 0 {
             // In real hardware, we'd jump to loop address if end bit set
             // Simplified: just wrap
        }
        
        voices[v] = voice
        return output
    }
    
    private func applyRange(_ nibble: Int32, range: Int) -> Int32 {
        return (nibble << range) >> 1
    }
    
    private func applyFilter(_ val: Int32, filter: Int, p1: Int16, p2: Int16) -> Int16 {
        var res = val
        let ip1 = Int32(p1)
        let ip2 = Int32(p2)
        
        switch filter {
        case 0: break
        case 1: res += ip1 + (-ip1 >> 4)
        case 2: res += (ip1 * 2) + ((-ip1 * 3) >> 5) - ip2 + (ip2 >> 4)
        case 3: res += (ip1 * 2) + ((-ip1 * 13) >> 6) - ip2 + ((ip2 * 3) >> 4)
        default: break
        }
        
        return Int16(max(-32768, min(32767, res)))
    }
    
    // MARK: - Noise
    
    private func noiseSample() -> Int16 {
        let bit = (noiseLFSR & 1) ^ ((noiseLFSR >> 1) & 1)
        noiseLFSR = (noiseLFSR >> 1) | (bit << 14)
        return (noiseLFSR & 1) != 0 ? -16384 : 16384 // Binary noise
    }
    
    // MARK: - Echo Buffer
    
    private func echoRead() -> (Int16, Int16) {
        guard echoEnable, let apu = apu else { return (0, 0) }
        let offset = echoBufferOffset + echoPtr
        let lLo = apu.ram[offset]
        let lHi = apu.ram[offset + 1]
        let rLo = apu.ram[offset + 2]
        let rHi = apu.ram[offset + 3]
        return (
            Int16(lHi) << 8 | Int16(lLo),
            Int16(rHi) << 8 | Int16(rLo)
        )
    }
    
    private func echoWrite(l: Int16, r: Int16) {
        guard echoEnable, let apu = apu else { return }
        let offset = echoBufferOffset + echoPtr
        apu.ram[offset] = UInt8(l & 0xFF)
        apu.ram[offset + 1] = UInt8((l >> 8) & 0xFF)
        apu.ram[offset + 2] = UInt8(r & 0xFF)
        apu.ram[offset + 3] = UInt8((r >> 8) & 0xFF)
        
        echoPtr += 4
        if echoPtr >= echoBufferSize { echoPtr = 0 }
    }
    
    // MARK: - Output
    
    func flushBuffer() -> [Float] {
        let buf = sampleBuffer
        sampleBuffer.removeAll(keepingCapacity: true)
        return buf
    }
}
