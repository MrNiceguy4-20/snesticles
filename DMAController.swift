import Foundation

class DMAController {
    weak var system: SNESSystem?

    struct Channel {
        var params: UInt8 = 0
        var dest: UInt8 = 0
        var srcAddr: UInt16 = 0
        var srcBank: UInt8 = 0
        var count: UInt16 = 0
        var hdmaActive: Bool = false
        var hdmaTableAddr: UInt16 = 0
        var hdmaLineCounter: UInt8 = 0
        var hdmaDoTransfer: Bool = false
        var indirectBank: UInt8 = 0
    }

    var channels = Array(repeating: Channel(), count: 8)
    var hdmaEnableMask: UInt8 = 0

    func read(_ addr: UInt32) -> UInt8 { return 0 }

    func write(_ addr: UInt32, data: UInt8) {
        let idx = Int((addr >> 4) & 0x7)
        let reg = addr & 0xF

        switch reg {
        case 0: channels[idx].params = data
        case 1: channels[idx].dest = data & 0xFF
        case 2: channels[idx].srcAddr = (channels[idx].srcAddr & 0xFF00) | UInt16(data)
        case 3: channels[idx].srcAddr = (channels[idx].srcAddr & 0x00FF) | (UInt16(data) << 8)
        case 4: channels[idx].srcBank = data
        case 5: channels[idx].count = (channels[idx].count & 0xFF00) | UInt16(data)
        case 6: channels[idx].count = (channels[idx].count & 0x00FF) | (UInt16(data) << 8)
        case 7: channels[idx].indirectBank = data
        default: break
        }
    }

    func enableDMA(channels mask: UInt8, bus: Bus) {
        for i in 0..<8 {
            if (mask & (1 << i)) != 0 {
                performDMATransfer(channelIdx: i, bus: bus)
            }
        }
    }

    private func performDMATransfer(channelIdx: Int, bus: Bus) {
        let ch = channels[channelIdx]

        let mode = ch.params & 0x07
        let directionCPUToPPU = (ch.params & 0x80) == 0
        let fixed = (ch.params & 0x08) != 0
        let decrement = (ch.params & 0x10) != 0

        var count = Int(ch.count)
        if count == 0 { count = 0x10000 }

        var src = UInt32(ch.srcAddr) | (UInt32(ch.srcBank) << 16)
        var dest = UInt32(0x2100 | UInt32(ch.dest))

        for _ in 0..<count {
            if directionCPUToPPU {
                let val = bus.read(src)
                bus.write(dest, data: val)
            } else {
                let val = bus.read(dest)
                bus.write(src, data: val)
            }

            if !fixed {
                if decrement {
                    src &-= 1
                } else {
                    src &+= 1
                }
            }

            switch mode {
            case 0: break
            case 1: dest = 0x2101
            case 2: dest = 0x2102
            case 3: dest = 0x2103
            case 4: dest = 0x2104
            case 5: dest = 0x2105
            case 6: dest = 0x2106
            case 7: dest = 0x2107
            default: break
            }
        }

        channels[channelIdx].srcAddr = UInt16(src & 0xFFFF)
        channels[channelIdx].count = 0
    }

    func enableHDMA(channels mask: UInt8) {
        hdmaEnableMask = mask
    }

    func resetHDMA(bus: Bus) {
        for i in 0..<8 {
            if (hdmaEnableMask & (1 << i)) != 0 {
                channels[i].hdmaActive = true
                channels[i].hdmaTableAddr = channels[i].srcAddr
                channels[i].hdmaLineCounter = 0
                channels[i].hdmaDoTransfer = false
            } else {
                channels[i].hdmaActive = false
            }
        }
    }

    func executeHDMA(line: Int, bus: Bus) {
        for i in 0..<8 {
            if !channels[i].hdmaActive { continue }

            var ch = channels[i]

            if ch.hdmaLineCounter == 0 {

                let table = UInt32(ch.hdmaTableAddr) | (UInt32(ch.srcBank) << 16)
                let header = bus.read(table)
                ch.hdmaTableAddr &+= 1

                if header == 0 {
                    ch.hdmaActive = false
                    channels[i] = ch
                    continue
                }

                ch.hdmaLineCounter = header & 0x7F
                ch.hdmaDoTransfer = (header & 0x80) != 0

                if (ch.params & 0x40) != 0 {
                    let lo = bus.read(UInt32(ch.hdmaTableAddr) | (UInt32(ch.srcBank) << 16))
                    let hi = bus.read(UInt32(ch.hdmaTableAddr + 1) | (UInt32(ch.srcBank) << 16))
                    ch.hdmaTableAddr &+= 2
                    let indirect = UInt16(hi) << 8 | UInt16(lo)
                    ch.srcAddr = indirect
                }
            }

            if ch.hdmaDoTransfer {
                performHDMADataTransfer(&ch, bus: bus)
            }

            ch.hdmaLineCounter &-= 1
            channels[i] = ch
        }
    }

    private func performHDMADataTransfer(_ ch: inout Channel, bus: Bus) {
        let mode = ch.params & 0x07
        let bbase = UInt32(0x2100 | UInt32(ch.dest))
        let aaddr = UInt32(ch.srcAddr) | (UInt32((ch.params & 0x40) != 0 ? ch.indirectBank : ch.srcBank) << 16)

        let transfers = transferCountForMode(mode)

        for i in 0..<transfers {
            let val = bus.read(aaddr + UInt32(i))
            bus.write(bbase + UInt32(i), data: val)
        }

        ch.srcAddr &+= UInt16(transfers)
    }

    private func transferCountForMode(_ mode: UInt8) -> Int {
        switch mode {
        case 0: return 1
        case 1: return 2
        case 2: return 2
        case 3: return 4
        case 4: return 4
        case 5: return 4
        case 6: return 2
        case 7: return 4
        default: return 1
        }
    }
}
