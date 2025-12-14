//
//  DSP1.swift
//  snits
//
//  Created by kevin on 2025-12-05.
//

import Foundation

final class DSP1 {
    // Buffers (The SNES communicates in 8-bit chunks)
    private var inputBuffer: [UInt8] = []
    private var outputBuffer: [UInt8] = []
    
    // Command State
    private var command: UInt8 = 0
    private var parameterCount = 0
    private var parameters: [UInt16] = []
    
    // Mode 7 Internal State (Raster)
    private var rasterX: Int16 = 0
    private var rasterY: Int16 = 0
    private var rasterZ: Int16 = 0
    
    // Global Attitude State (Pilotwings)
    private var attitudeX: Int16 = 0
    private var attitudeY: Int16 = 0
    private var attitudeZ: Int16 = 0
    
    func reset() {
        inputBuffer.removeAll()
        outputBuffer.removeAll()
        parameters.removeAll()
        command = 0
        parameterCount = 0
    }
    
    // MARK: - External Interface
    
    /// Write a byte to the DSP-1 Data Register
    func write(_ value: UInt8) {
        inputBuffer.append(value)
        
        // We need 2 bytes to form a 16-bit word
        if inputBuffer.count >= 2 {
            let low = UInt16(inputBuffer[0])
            let high = UInt16(inputBuffer[1])
            let word = (high << 8) | low
            inputBuffer.removeAll()
            
            processWord(word)
        }
    }
    
    /// Read a byte from the DSP-1 Data Register
    func read() -> UInt8 {
        guard !outputBuffer.isEmpty else { return 0xFF }
        return outputBuffer.removeFirst()
    }
    
    /// Status Register (bit 7: Data Available, bit 6: Input buffer full?)
    func readStatus() -> UInt8 {
        var status: UInt8 = 0
        if !outputBuffer.isEmpty { status |= 0x80 }
        // We process instantly, so input is never "full", but games check this
        return status
    }
    
    // MARK: - Command Processing
    
    private func processWord(_ word: UInt16) {
        if parameters.isEmpty && command == 0 {
            // New Command
            command = UInt8(word & 0xFF) // Commands are usually the first byte
            // Some flows might treat the whole word as parameter if in a stream
            // But standard DSP1 protocol: First byte is command.
            
            // However, the DSP1 accepts a Command byte, then parameter words.
            // The word passed in here is 16-bits.
            // Actually, the command is often the upper byte or separate write.
            // For simplicity in this HLE:
            // If we are not waiting for parameters, this word contains the command.
            
            // Correct HLE flow:
            // The input is a stream of 16-bit words.
            // The first word contains the Command in the low byte (usually).
            
            command = UInt8(word & 0xFF)
            parameterCount = requiredParameters(for: command)
            
            // Some commands (like 0x1A) take 1 parameter, which is THIS word if it's 16-bit?
            // No, standard flow is: Command Byte -> Param Words.
            // Since we reconstructed 'word' from 2 bytes, if the SNES wrote Command (8-bit), we have it.
            
            if parameterCount == 0 {
                execute()
            }
        } else {
            parameters.append(word)
            if parameters.count >= parameterCount {
                execute()
            }
        }
    }
    
    private func requiredParameters(for cmd: UInt8) -> Int {
        switch cmd {
        case 0x00: return 2 // Multiply
        case 0x10: return 2 // Inverse
        case 0x20: return 2 // Triangle
        case 0x04: return 2 // Radius
        case 0x08: return 2 // Range
        case 0x18: return 2 // Distance
        case 0x28: return 2 // Rotate
        case 0x02: return 2 // Parameter
        case 0x0A: return 1 // Raster
        case 0x1A: return 1 // Raster
        case 0x01: return 4 // Attitude
        case 0x11: return 4 // Attitude
        case 0x21: return 4 // Attitude
        case 0x0D: return 3 // Objective
        case 0x1D: return 3 // Objective
        case 0x2D: return 3 // Objective
        case 0x03: return 1 // Project
        case 0x13: return 1 // Project
        case 0x23: return 1 // Project
        case 0x0B: return 7 // Target
        case 0x1B: return 7 // Target
        case 0x2B: return 7 // Target
        default: return 0
        }
    }
    
    private func execute() {
        var results: [Int16] = []
        
        switch command {
        // Simple Math
        case 0x00: // Multiply (K * A)
            let k = Int16(bitPattern: parameters[0])
            let a = Int16(bitPattern: parameters[1])
            let res = (Int32(k) * Int32(a)) >> 15
            results = [Int16(truncatingIfNeeded: res)]
            
        case 0x10: // Inverse (A / B)
            // Simplified inverse approximation
            let a = Int16(bitPattern: parameters[0])
            // let b = parameters[1]... logic complex
            results = [a] // Placeholder
            
        // Mode 7 Rotation
        case 0x20: // Rotate (X, Y, Angle)
            let angle = Double(parameters[0]) * .pi / 32768.0
            let x = Double(Int16(bitPattern: parameters[1]))
            let c = cos(angle)
            let s = sin(angle)
            // Need a second parameter for Y usually, but protocol might vary.
            // This is a minimal implementation for compilation.
            results = [Int16(x * c), Int16(x * s)]
            
        // Mario Kart / Pilotwings Raster Math
        case 0x0A: // Raster (Mode 7)
            // Parameters: [VS, H]
            // Simplification:
            results = [0, 0, 0, 0]
            
        case 0x11, 0x21, 0x01: // Attitude Matrix
            // 3D Rotation Calculation
            results = [0, 0, 0] // Placeholder for matrix rows
            
        case 0x06: // Project
            // 3D Projection
             results = [0, 0, 0]
             
        default:
            // Unknown command or unimplemented
            results = []
        }
        
        // Push results to output buffer (Little Endian)
        for res in results {
            let u = UInt16(bitPattern: res)
            outputBuffer.append(UInt8(u & 0xFF))
            outputBuffer.append(UInt8((u >> 8) & 0xFF))
        }
        
        // Reset state for next command
        parameters.removeAll()
        command = 0
        parameterCount = 0
    }
    
    // MARK: - DSP Math Functions
    
    private func inverse(_ k: Int16) -> Int16 {
        guard k != 0 else { return 0x7FFF }
        let sign = k < 0 ? -1 : 1
        let absK = abs(k)
        let res = Int32(0x4000000 / Int32(absK)) * Int32(sign)
        return Int16(truncatingIfNeeded: res >> 15)
    }
}
