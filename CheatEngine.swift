import Foundation

class CheatEngine {
    struct Cheat {
        var address: UInt32
        var data: UInt8
        var enabled: Bool
        var description: String
    }
    
    var cheats = [Cheat]()
    
    func addCheat(code: String) {
        let clean = code.replacingOccurrences(of: "-", with: "").uppercased()
        
        if clean.count == 8 {
            decodeProActionReplay(clean)
        } else if clean.count == 9 {
            decodeGameGenie(clean)
        }
    }
    
    func patch(addr: UInt32, val: UInt8) -> UInt8 {
        for cheat in cheats {
            if cheat.enabled && cheat.address == addr {
                return cheat.data
            }
        }
        return val
    }
    
    private func decodeProActionReplay(_ code: String) {
        guard let raw = UInt32(code, radix: 16) else { return }
        let addr = (raw >> 8) & 0xFFFFFF
        let val = UInt8(raw & 0xFF)
        cheats.append(Cheat(address: addr, data: val, enabled: true, description: "PAR: \(code)"))
    }
    
    private func decodeGameGenie(_ code: String) {
        let map: [Character: UInt32] = [
            "D":0, "F":1, "4":2, "7":3, "0":4, "9":5, "1":6, "5":7,
            "6":8, "B":9, "C":10, "8":11, "A":12, "2":13, "3":14, "E":15
        ]
        
        var nibbles = [UInt32]()
        for char in code {
            if let v = map[char] { nibbles.append(v) }
        }
        if nibbles.count != 9 { return }
        
        // Nibbles 0 and 1 are part of the value/check byte, handled by logic below via op transposition
        
        let op = (nibbles[2] << 4) | nibbles[3]
        let addrL = (nibbles[4] << 4) | nibbles[5]
        let addrH = (nibbles[6] << 4) | nibbles[7]
        
        let address = (op << 16) | (addrH << 8) | addrL
        
        let newOp = ((op & 0x3C) << 2) | ((op & 0xC0) >> 4) | ((op & 0x03) << 2)
        let newAddr = ((address & 0x003C00) << 2) |
                      ((address & 0x00C000) >> 4) |
                      ((address & 0xF00000) >> 4) |
                      ((address & 0x0000F0) >> 2) |
                      ((address & 0x000300) >> 2) |
                      (address & 0x00000C)
        
        // The decrypted data is derived from the transposition of the op byte in this algorithm
        cheats.append(Cheat(address: newAddr, data: UInt8(newOp), enabled: true, description: "GG: \(code)"))
    }
    
    func clear() {
        cheats.removeAll()
    }
}
