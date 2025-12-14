import Foundation
import Combine
import GameController
import AVFoundation
import CoreVideo // For CVDisplayLink

final class SNESSystem: ObservableObject {
    @Published var statusMessage: String = "Ready"
    @Published var cartridgeTitle: String = ""
    @Published var isRunning = false
    @Published var isTurbo = false
    @Published var activeCheats: [String] = []
    @Published var cpuLoggingEnabled = false
    
    var cpu: CPU!
    var ppu: PPU!
    var apu: APU!
    var bus: Bus!
    var dma: DMAController!
    var gsu: GSU!
    var dsp1: DSP1!
    var renderer: MetalRenderer!
    var audioDriver: AudioDriver!
    var cheatEngine: CheatEngine!
    
    private var joypad1: UInt16 = 0
    private var displayLink: CVDisplayLink? // macOS Display Link
    
    init() {
        setupEmulator()
        setupDisplayLink()
        setupGameController()
    }
    
    deinit {
        if let link = displayLink { CVDisplayLinkStop(link) }
    }
    
    private func setupEmulator() {
        renderer = MetalRenderer()
        audioDriver = AudioDriver()
        ppu = PPU(renderer: renderer)
        apu = APU()
        apu.setDSP(DSP())
        bus = Bus(ppu: ppu, apu: apu)
        bus.system = self
        gsu = bus.gsu
        dsp1 = DSP1()
        dma = DMAController(bus: bus)
        bus.dma = dma
        cpu = CPU(bus: bus)
        bus.cpu = cpu
        cheatEngine = CheatEngine()
    }
    
    private func setupDisplayLink() {
        // macOS CVDisplayLink Setup
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let link = displayLink else { return }
        
        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, ctx in
            let sys = Unmanaged<SNESSystem>.fromOpaque(ctx!).takeUnretainedValue()
            sys.frameStep()
            return kCVReturnSuccess
        }
        
        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
    }
    
    func run() {
        guard !isRunning, let link = displayLink else { return }
        isRunning = true
        CVDisplayLinkStart(link)
        statusMessage = "Running"
    }
    
    func pause() {
        guard let link = displayLink else { return }
        isRunning = false
        CVDisplayLinkStop(link)
        statusMessage = "Paused"
    }
    
    // Called on background thread by CVDisplayLink
    func frameStep() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.emulateFrame()
        }
    }
    
    private func emulateFrame() {
        let cyclesPerFrame = isTurbo ? 357366.0 * 4 : 357366.0
        var cyclesDone = 0.0
        
        while cyclesDone < cyclesPerFrame {
            let c = cpu.clock()
            cyclesDone += Double(c)
            apu.clock(c)
            if bus.gsu.isRunning { bus.gsu.clock(c) }
        }
        
        ppu.endFrame()
        if let dsp = apu.dsp { audioDriver.queueSamples(dsp.flushBuffer()) }
        bus.joypad1 = joypad1
        if ppu.nmiFlag { cpu.nmi() }
    }
    
    // MARK: - Save/Load with Fixed Labels
    func quickSave() {
        let s = Serializer()
        cpu.save(to: s)
        ppu.save(to: s)
        apu.save(s)
        bus.save(to: s)
        try? s.data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("snes.sav"))
        statusMessage = "Saved"
    }
    
    func quickLoad() {
        guard let data = try? Data(contentsOf: FileManager.default.temporaryDirectory.appendingPathComponent("snes.sav")) else { return }
        let s = Serializer(data: data)
        cpu.load(from: s)
        ppu.load(from: s)
        apu.load(s)
        bus.load(from: s)
        statusMessage = "Loaded"
    }
    
    // Passthroughs
    func reset() { cpu.reset(); ppu.reset(); bus.reset(); statusMessage = "Reset" }
    func softReset() { cpu.reset(); statusMessage = "Soft Reset" }
    func powerCycle() { setupEmulator(); statusMessage = "Power Cycle" }
    func toggleLogging(_ val: Bool) { cpuLoggingEnabled = val }
    func addCheat(_ c: String) { cheatEngine.addCheat(c); activeCheats = cheatEngine.cheats.map { $0.description } }
    
    func loadROM(from url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        loadROM(data: data)
    }
    func loadROM(data: Data) {
        pause()
        let cart = Cartridge(data: data)
        bus.insertCartridge(cart)
        cartridgeTitle = cart.title
        reset()
        run()
    }
    
    // Input Handling
    func handleKeyDown(_ code: UInt16) {
        switch code {
        case 0x24: joypad1 |= 0x1000 // Return -> Start
        case 0x31: isTurbo = true    // Space -> Turbo
        // Add others...
        default: break
        }
    }
    func handleKeyUp(_ code: UInt16) {
        switch code {
        case 0x24: joypad1 &= ~0x1000
        case 0x31: isTurbo = false
        // Add others...
        default: break
        }
    }
    
    func testPattern(_ type: TestPattern) { ppu.drawTestPattern(type) }
    
    private func setupGameController() {} // Placeholder
}
