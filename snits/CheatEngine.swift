//
//  CheatEngine.swift
//  snits
//
//  Created by kevin on 2025-12-05.
//

import Foundation

final class CheatEngine {
    struct Cheat {
        let address: UInt32
        let data: UInt8
        let compare: UInt8?         // For compare-type Game Genie codes (Conditional patch)
        var enabled: Bool
        var description: String
    }
    
    private(set) var cheats: [Cheat] = []
    
    // MARK: - API
    
    func addCheat(_ code: String) {
        // clean up input: remove dashes, spaces, make uppercase
        let clean = code.replacingOccurrences(of: " ", with: "")
                        .replacingOccurrences(of: "-", with: "")
                        .uppercased()
        
        // Validation helpers
        let isHex = clean.allSatisfy { $0.isHexDigit }
        
        if clean.count == 8 && isHex {
            // Pro Action Replay (8 hex digits: AAAAAADD)
            decodePAR(clean)
        } else if (clean.count == 6 || clean.count == 8) && isHex {
            // Game Genie (6 or 8 chars, using GG cipher)
            // Note: GG uses A-F but also other chars, strictly mapped below.
            // If strictly hex chars, it might be PAR, but 6-char PAR isn't standard SNES.
            // We assume GG if length matches standard GG lengths.
            decodeGameGenie(clean)
        } else {
            print("Invalid cheat code format: \(code)")
        }
    }
    
    /// Called by the Bus on every read. Returns the patched value if a cheat is active.
    func patch(address: UInt32, value: UInt8) -> UInt8 {
        // Performance note: Linear scan is fine for < 100 cheats.
        // For massive lists, a Dictionary [UInt32: [Cheat]] would be better.
        for cheat in cheats {
            guard cheat.enabled else { continue }
            
            if cheat.address == address {
                if let compare = cheat.compare {
                    // Game Genie "Compare" type: Only patch if the real value matches the compare byte.
                    // This prevents patching bank switching code or dynamic variables incorrectly.
                    if value == compare {
                        return cheat.data
                    }
                } else {
                    // Always patch (PAR style or non-compare GG)
                    return cheat.data
                }
            }
        }
        return value
    }
    
    func toggleCheat(at index: Int) {
        guard cheats.indices.contains(index) else { return }
        cheats[index].enabled.toggle()
    }
    
    func removeAll() {
        cheats.removeAll()
    }
    
    // MARK: - Pro Action Replay (8-digit hex: AAAAAADD)
    // Format: Bank(2) + Offset(4) + Data(2)
    private func decodePAR(_ code: String) {
        guard let raw = UInt32(code, radix: 16) else { return }
        
        let address = (raw >> 8) & 0xFFFFFF
        let data = UInt8(raw & 0xFF)
        
        let desc = "PAR: \(code) → $\(String(format: "%06X", address)):$\(String(format: "%02X", data))"
        cheats.append(Cheat(address: address, data: data, compare: nil, enabled: true, description: desc))
    }
    
    // MARK: - Game Genie Decoding
    // 6-char: Address (24-bit) + Data (8-bit)
    // 8-char: Address (24-bit) + Data (8-bit) + Compare (8-bit)
    private func decodeGameGenie(_ code: String) {
        // Game Genie Cipher Map
        let map: [Character: UInt8] = [
            "D":0, "F":1, "4":2, "7":3,
            "0":4, "9":5, "1":6, "5":7,
            "6":8, "B":9, "C":10, "8":11,
            "A":12, "2":13, "3":14, "E":15
        ]
        
        var bits: [UInt8] = []
        for c in code {
            guard let v = map[c] else { return } // Invalid char for Game Genie
            bits.append(v)
        }
        
        guard bits.count == 6 || bits.count == 8 else { return }
        let hasCompare = bits.count == 8
        
        // Prepare array for easy indexing
        let b = bits
        
        var address: UInt32 = 0
        var data: UInt8 = 0
        var compare: UInt8? = nil
        
        if hasCompare {
            // 8-character: DDDD-DDDD (with compare)
            // Transposition algorithm
            data     = ((b[7] & 7) << 5) | ((b[5] & 7) << 2) | ((b[3] & 4) >> 1) | (b[3] & 3)
            compare  = ((b[6] & 7) << 5) | ((b[4] & 7) << 2) | ((b[2] & 4) >> 1) | (b[2] & 3)
            
            address  = 0x800000 // Usually targets ROM area
            address |= (UInt32(b[7] & 8) << 20)
            address |= (UInt32(b[6] & 8) << 16)
            address |= (UInt32(b[5] & 8) << 12)
            address |= (UInt32(b[4] & 8) << 8)
            address |= (UInt32(b[3] & 8) << 4)
            address |= UInt32(b[2] & 8)
            address |= (UInt32(b[1]) << 16)
            address |= (UInt32(b[0]) << 8)
            
        } else {
            // 6-character: DDDD-DD
            data    = ((b[3] & 7) << 5) | ((b[5] & 7) << 2) | ((b[4] & 4) >> 1) | (b[4] & 3)
            
            address = 0x800000
            address |= (UInt32(b[3] & 8) << 20)
            address |= (UInt32(b[2] & 7) << 16)
            address |= (UInt32(b[1]) << 8)
            address |= UInt32(b[0])
        }
        
        let desc = hasCompare
            ? "GG: \(code) → $\(String(format: "%06X", address)) = $\(String(format: "%02X", data)) (if $\(String(format: "%02X", compare!)))"
            : "GG: \(code) → $\(String(format: "%06X", address)) = $\(String(format: "%02X", data))"
        
        cheats.append(Cheat(
            address: address,
            data: data,
            compare: compare,
            enabled: true,
            description: desc
        ))
    }
}

// MARK: - Extensions

extension Character {
    var isHexDigit: Bool {
        return self.isNumber || ("a"..."f").contains(self.lowercased())
    }
}
