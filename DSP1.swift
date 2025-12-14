import Foundation

class DSP1 {
    var commandBuffer = [UInt16]()
    var outputBuffer = [UInt16]()
    
    var command: UInt8 = 0
    var inputCount: Int = 0
    var outputCount: Int = 0
    
    func reset() {
        commandBuffer.removeAll(keepingCapacity: true)
        outputBuffer.removeAll(keepingCapacity: true)
        command = 0
        inputCount = 0
        outputCount = 0
    }
    
    func readStatus() -> UInt8 {
        var status: UInt8 = 0
        if outputBuffer.count > 0 { status |= 0x80 }
        if inputCount < expectedInputSize(command) { status |= 0x40 }
        return status
    }
    
    func writeData(_ data: UInt8) {
        if outputBuffer.isEmpty {
            if inputCount == 0 {
                command = data
                commandBuffer.append(UInt16(data))
                inputCount += 1
            } else {
                if commandBuffer.count > 0 {
                    let last = commandBuffer.removeLast()
                    commandBuffer.append(last | (UInt16(data) << 8))
                    inputCount += 1
                } else {
                    commandBuffer.append(UInt16(data))
                }
            }
            
            if inputCount >= expectedInputSize(command) {
                execute()
                inputCount = 0
                commandBuffer.removeAll(keepingCapacity: true)
            }
        }
    }
    
    func readData() -> UInt8 {
        if !outputBuffer.isEmpty {
            let val = outputBuffer[0]
            outputBuffer[0] = val >> 8
            if (outputBuffer[0] == 0) {
                outputBuffer.removeFirst()
            }
            return UInt8(val & 0xFF)
        }
        return 0
    }
    
    func expectedInputSize(_ cmd: UInt8) -> Int {
        switch cmd {
        case 0x00: return 2
        case 0x20: return 2
        case 0x10: return 2
        case 0x04: return 2
        case 0x08: return 3
        case 0x18: return 4
        case 0x28: return 3
        case 0x0A: return 1
        case 0x1A: return 1
        default: return 0
        }
    }
    
    func execute() {
        switch command {
        case 0x00:
            let K = Int16(bitPattern: commandBuffer[0])
            let A = Int16(bitPattern: commandBuffer[1])
            let res = (Int32(K) * Int32(A)) >> 15
            outputBuffer.append(UInt16(bitPattern: Int16(res)))
            
        case 0x20:
            let X = Int16(bitPattern: commandBuffer[0])
            let Y = Int16(bitPattern: commandBuffer[1])
            outputBuffer.append(UInt16(bitPattern: Y))
            outputBuffer.append(UInt16(bitPattern: X))
            
        case 0x10:
            let K = Int16(bitPattern: commandBuffer[0])
            let A = Int16(bitPattern: commandBuffer[1])
            let res = (Int32(K) * Int32(A)) >> 15
            outputBuffer.append(UInt16(bitPattern: Int16(res)))
            
        case 0x04:
            let angle = commandBuffer[0]
            let radius = commandBuffer[1]
            let s = sin(Double(angle) * .pi / 32768.0) * Double(radius)
            let c = cos(Double(angle) * .pi / 32768.0) * Double(radius)
            outputBuffer.append(UInt16(bitPattern: Int16(s)))
            outputBuffer.append(UInt16(bitPattern: Int16(c)))
            
        default:
            outputBuffer.append(0)
        }
    }
}
