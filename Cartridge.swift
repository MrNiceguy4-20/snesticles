import Foundation

class Cartridge {
    var romData: Data
    var sram: [UInt8]
    var hasBattery: Bool = false
    var hasDSP1: Bool = false
    var hasGSU: Bool = false

    var title: String = "Unknown"
    var romType: UInt8 = 0
    var romSize: UInt8 = 0
    var sramSize: UInt8 = 0
    var region: UInt8 = 0

    init(data: Data) {

        if data.count % 0x8000 == 0x200 {
            print("Stripping 512-byte copier header")
            self.romData = data.subdata(in: 0x200..<data.count)
        } else {
            self.romData = data
        }

        self.sram = Array(repeating: 0xFF, count: 128 * 1024)
        parseHeader()
    }

    func parseHeader() {

        let loScore = scoreHeader(offset: 0x7FC0)
        let hiScore = scoreHeader(offset: 0xFFC0)

        let headerAddr = (loScore >= hiScore) ? 0x7FC0 : 0xFFC0

        if headerAddr + 21 <= romData.count {
            let titleData = romData.subdata(in: headerAddr..<(headerAddr+21))
            title = String(decoding: titleData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if headerAddr + 0x15 < romData.count {
            romType = romData[headerAddr + 0x15]
            romSize = romData[headerAddr + 0x17]
            sramSize = romData[headerAddr + 0x18]
            region = romData[headerAddr + 0x19]

            let chipset = romData[headerAddr + 0x16]

            if chipset == 0x03 || chipset == 0x04 || chipset == 0x05 { hasDSP1 = true }

            if chipset == 0x13 || chipset == 0x14 || chipset == 0x15 || chipset == 0x1A { hasGSU = true }

            hasBattery = (romType & 0x02) != 0
        }

        var size = 0
        if sramSize > 0 {
            size = 1024 << sramSize
        }
        if size > sram.count { size = sram.count }

        print("ROM Loaded: \(title)")
        print("Mode: \(loScore >= hiScore ? "LoROM" : "HiROM")")
        print("Type: \(String(format:"%02X", romType))")
    }

    func scoreHeader(offset: Int) -> Int {
        if offset + 0x40 > romData.count { return 0 }
        var score = 0

        let resetLo = romData[offset + 0x3C]
        let resetHi = romData[offset + 0x3D]
        let resetVec = (UInt16(resetHi) << 8) | UInt16(resetLo)
        if resetVec >= 0x8000 { score += 1 }

        let checkLo = UInt16(romData[offset + 0x1E])
        let checkHi = UInt16(romData[offset + 0x1F])
        let compLo = UInt16(romData[offset + 0x1C])
        let compHi = UInt16(romData[offset + 0x1D])

        let checksum = (checkHi << 8) | checkLo
        let complement = (compHi << 8) | compLo

        if (checksum &+ complement) == 0xFFFF { score += 4 }

        var validChars = 0
        for i in 0..<21 {
            let c = romData[offset + i]
            if (c >= 32 && c <= 126) { validChars += 1 }
        }
        if validChars >= 15 { score += 2 }

        return score
    }

    func read(_ address: UInt32) -> UInt8 {
        if address < romData.count {
            return romData[Int(address)]
        }

        if romData.count > 0 {
            return romData[Int(address) % romData.count]
        }
        return 0xEA
    }

    func readSRAM(_ address: UInt32) -> UInt8 {
        let mask = UInt32(sram.count - 1)
        return sram[Int(address & mask)]
    }

    func writeSRAM(_ address: UInt32, data: UInt8) {
        let mask = UInt32(sram.count - 1)
        sram[Int(address & mask)] = data
    }

    func loadSRAM(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            for i in 0..<min(data.count, sram.count) { sram[i] = data[i] }
        } catch {
            print("SRAM Load Error: \(error)")
        }
    }

    func saveSRAM(to url: URL) {
        do {
            try Data(sram).write(to: url)
        } catch {
            print("SRAM Save Error: \(error)")
        }
    }
}
