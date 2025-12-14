import Foundation
import Combine
import AppKit
import GameController

class SNESSystem: ObservableObject {
    @Published var cpu: CPU!
    @Published var statusMessage: String = "No Cartridge Loaded"
    @Published var cartridgeLoaded: Bool = false
    @Published var isTurbo: Bool = false
    @Published var isRunning: Bool = false
    
    var ppu: PPU
    var apu: APU
    var dsp: DSP
    var bus: Bus
    var renderer: MetalRenderer
    var audioDriver: AudioDriver
    
    private var timer: Timer?
    var currentInput: UInt16 = 0
    
    init() {
        self.renderer = MetalRenderer()
        self.ppu = PPU(renderer: renderer)
        self.dsp = DSP()
        self.apu = APU(dsp: dsp)
        self.bus = Bus(ppu: ppu, apu: apu)
        self.cpu = CPU(bus: bus)
        self.audioDriver = AudioDriver()
        
        self.bus.dmaController.system = self
        self.bus.system = self
        
        setupControllerObserver()
    }
    
    func saveState(to url: URL) {
        let s = Serializer()
        cpu.save(s); ppu.save(s); apu.save(s); dsp.save(s); bus.save(s)
        do { try s.data.write(to: url); statusMessage = "State Saved" } catch { print(error) }
    }
    
    func loadState(from url: URL) {
        do {
            let data = try Data(contentsOf: url); let s = Serializer(data: data)
            cpu.load(s); ppu.load(s); apu.load(s); dsp.load(s); bus.load(s)
            statusMessage = "State Loaded"
        } catch { print(error) }
    }
    
    func setupControllerObserver() {
        NotificationCenter.default.addObserver(self, selector: #selector(controllerDidConnect), name: .GCControllerDidConnect, object: nil)
    }
    @objc func controllerDidConnect(note: Notification) {
        guard let controller = note.object as? GCController else { return }
        controller.extendedGamepad?.valueChangedHandler = { [weak self] (gamepad, element) in self?.updateControllerInput(gamepad) }
        statusMessage = "Controller Connected: \(controller.vendorName ?? "Generic")"
    }
    func updateControllerInput(_ gamepad: GCExtendedGamepad) {
        var input: UInt16 = 0
        if gamepad.buttonB.isPressed { input |= 0x8000 }
        if gamepad.buttonY.isPressed { input |= 0x4000 }
        if gamepad.buttonMenu.isPressed { input |= 0x2000 }
        if gamepad.buttonOptions?.isPressed == true { input |= 0x1000 }
        if gamepad.dpad.up.isPressed { input |= 0x0800 }
        if gamepad.dpad.down.isPressed { input |= 0x0400 }
        if gamepad.dpad.left.isPressed { input |= 0x0200 }
        if gamepad.dpad.right.isPressed { input |= 0x0100 }
        if gamepad.buttonA.isPressed { input |= 0x0080 }
        if gamepad.buttonX.isPressed { input |= 0x0040 }
        if gamepad.leftShoulder.isPressed { input |= 0x0020 }
        if gamepad.rightShoulder.isPressed { input |= 0x0010 }
        currentInput = input
        
        if gamepad.rightTrigger.isPressed && !isTurbo { toggleTurbo(true) }
        else if !gamepad.rightTrigger.isPressed && isTurbo { toggleTurbo(false) }
    }
    
    func toggleTurbo(_ on: Bool) {
        isTurbo = on
        if isRunning { updateTimer() }
    }
    
    func toggleLogging(_ on: Bool) {
        cpu.enableLogging = on
        statusMessage = on ? "CPU Logging: ON" : "CPU Logging: OFF"
    }
    
    func runVideoTest() {
        // Stop normal emulation so the test pattern stays visible.
        stopEmulation()
        ppu.drawTestPattern()
        ppu.renderer.updateTexture(pixels: ppu.frameBuffer)
        statusMessage = "Running Video Test..."
    }

    func runHiresTest() {
        stopEmulation()
        ppu.drawHiresTestPattern()
        ppu.renderer.updateTexture(pixels: ppu.frameBuffer)
        statusMessage = "Hires Test Pattern"
    }

    func runColorBarsTest() {
        stopEmulation()
        ppu.drawColorBarsTestPattern()
        ppu.renderer.updateTexture(pixels: ppu.frameBuffer)
        statusMessage = "Color Bars Test Pattern"
    }

    func runGridTest() {
        stopEmulation()
        ppu.drawGridTestPattern()
        ppu.renderer.updateTexture(pixels: ppu.frameBuffer)
        statusMessage = "Grid Test Pattern"
    }

    
    func runAudioTest() {
        audioDriver.playTestTone()
        audioDriver.start()
        statusMessage = "Playing 440Hz Test Tone..."
    }
    
    func loadRom(data: Data) {
        let cartridge = Cartridge(data: data)
        bus.insertCartridge(cartridge)
        
        cpu.reset()
        ppu.reset()
        apu.reset()
        cartridgeLoaded = true
        statusMessage = "Loaded: \(data.count / 1024)KB"
        
        audioDriver.start()
        startEmulation()
        objectWillChange.send()
    }
    
    func saveSRAM() { if let cart = bus.cartridge, let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first { cart.saveSRAM(to: docDir.appendingPathComponent("saved_game.srm")); statusMessage = "Saved SRAM" } }
    func loadSRAM() { if let cart = bus.cartridge, let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first { cart.loadSRAM(from: docDir.appendingPathComponent("saved_game.srm")); statusMessage = "Loaded SRAM" } }
    
    func startEmulation() {
        isRunning = true
        updateTimer()
    }
    
    func stopEmulation() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }
    
    private func updateTimer() {
        timer?.invalidate()
        let interval = isTurbo ? 0.002 : 0.016
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in self.frame() }
    }
    
    
    func frame() {
        guard cartridgeLoaded else { return }

        // Start-of-frame HDMA setup
        bus.dmaController.resetHDMA(bus: bus)

        // NTSC Total scanlines = 262 (Lines 0 through 261).
        let totalScanlines = 262
        let cpuCyclesPerScanline = 1364

        // Loop over all 262 scanlines of the frame.
        for line in 0..<totalScanlines {

            // --- 1. IRQ/NMI Check (for the line the CPU is about to execute) ---
            
            // Check the NMI Status flag in the Bus, which is set by PPU.stepScanline()
            // when VBLANK starts. NMI is level-triggered and should be checked frequently.
            if (bus.nmiStatus & 0x80) != 0 {
                cpu.nmi()
            }

            // H/V IRQ evaluation
            if bus.irqEnabled {
                // The V-Counter is ppu.currentScanline (set by the PPU)
                let hPos: UInt16 = 170 // Approximate cycle count for H-IRQ
                if bus.checkIRQ(vCounter: ppu.currentScanline, hCounter: hPos) {
                    cpu.irq()
                }
            }

            // HDMA is executed per-scanline.
            bus.dmaController.executeHDMA(line: line, bus: bus)


            // --- 2. Clock CPU/APU for one scanline's worth of cycles (approx 1364) ---
            var cycles = 0
            while cycles < cpuCyclesPerScanline {
                let prevCyclesRemaining = cpu.cyclesRemaining

                // One CPU cycle (or substep)
                cpu.clock()

                // Keep APU in lockstep.
                apu.clock()

                // Drive the DSP mixer (approx 32kHz, which is ~112 CPU cycles).
                if (cycles % 120) == 0 {
                    dsp.mix()
                }

                // Run SuperFX if active
                if bus.gsu.isRunning {
                    bus.gsu.step()
                }

                // Roughly account for how many CPU cycles were consumed.
                if cpu.cyclesRemaining > prevCyclesRemaining {
                    cycles += (prevCyclesRemaining + 2)
                } else if cpu.cyclesRemaining == 0 {
                    cycles += 2
                } else {
                    cycles += 1
                }
            }
            
            // --- 3. Step PPU to the next line (handles rendering, VBLANK, NMI signaling) ---
            // This call renders the current line and increments the internal scanline counter.
            // It also signals VBLANK and NMI (via the Bus) when line 225 is reached.
            ppu.stepScanline()
        }

        // --- 4. End of Frame Audio Flush ---
        let samples = dsp.flushBuffer()
        if !samples.isEmpty {
            audioDriver.queueSamples(samples)
        }
    }
func step() {
        guard cartridgeLoaded else { return }
        cpu.clock()
        apu.clock()
        objectWillChange.send()
    }
    
    func reset() {
        cpu.reset()
        ppu.reset()
        apu.reset()
        objectWillChange.send()
    }
    
    func handleKey(code: UInt16, isDown: Bool) {
        let mask: UInt16
        switch code {
        case 6: mask = 0x8000
        case 7: mask = 0x4000
        case 49: mask = 0x2000
        case 36: mask = 0x1000
        case 126: mask = 0x0800
        case 125: mask = 0x0400
        case 123: mask = 0x0200
        case 124: mask = 0x0100
        case 0: mask = 0x0080
        case 1: mask = 0x0040
        case 12: mask = 0x0020
        case 13: mask = 0x0010
        case 3: toggleTurbo(isDown); return
        default: return
        }
        if isDown {
            currentInput |= mask
        } else {
            currentInput &= ~mask
        }
    }
}
