enum TestPattern {
    case colorBars, grid, hires, audio
}
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject  var emulator: SNESSystem
    @State private var isImporting = false
    @State private var cheatInput = ""
    @State private var showSidebar = true
    
    var body: some View {
        HSplitView {
            // MARK: - Game Screen Area
            ZStack {
                Color.black.ignoresSafeArea()
                
                // Keyboard Input Handler (Invisible background view)
                KeyboardGlobalHandler(emulator: emulator)
                
                if emulator.isRunning {
                    // Render the SNES output
                    if let renderer = emulator.renderer {
                        MetalView(renderer: renderer)
                            .aspectRatio(256.0/224.0, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    
                    // Overlays
                    VStack {
                        HStack {
                            Spacer()
                            if emulator.isTurbo {
                                Text("TURBO")
                                    .font(.system(size: 12, weight: .heavy))
                                    .foregroundColor(.yellow)
                                    .padding(4)
                                    .background(Color.black.opacity(0.6))
                                    .cornerRadius(4)
                                    .padding()
                            }
                        }
                        Spacer()
                    }
                } else {
                    // Placeholder State
                    VStack(spacing: 20) {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 80))
                            .foregroundColor(.gray.opacity(0.3))
                        
                        Text("SwiftSNES")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(.gray)
                        
                        Button("Load ROM") { isImporting = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        
                        Text("Drag & drop .sfc or .smc file")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(minWidth: 512, minHeight: 448) // Minimum 2x scale
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                loadDroppedROM(providers)
                return true
            }
            
            // MARK: - Sidebar Controls
            if showSidebar {
                VStack(alignment: .leading, spacing: 16) {
                    // Header
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Status")
                            .font(.headline)
                        if !emulator.cartridgeTitle.isEmpty {
                            Text(emulator.cartridgeTitle)
                                .font(.subheadline)
                                .foregroundColor(.blue)
                                .lineLimit(2)
                        } else {
                            Text("No Cartridge")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Text(emulator.statusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top)
                    
                    Divider()
                    
                    // Main Controls
                    GroupBox("Controls") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Button(action: {
                                    emulator.isRunning ? emulator.pause() : emulator.run()
                                }) {
                                    Label(emulator.isRunning ? "Pause" : "Run",
                                          systemImage: emulator.isRunning ? "pause.fill" : "play.fill")
                                }
                                .keyboardShortcut(.space, modifiers: []) // Spacebar toggle
                                
                                Button(action: { emulator.reset() }) {
                                    Label("Reset", systemImage: "arrow.counterclockwise")
                                }
                            }
                            
                            Toggle("Turbo Mode (Hold T)", isOn: $emulator.isTurbo)
                                .toggleStyle(.switch)
                        }
                        .padding(4)
                    }
                    
                    // Cheats
                    GroupBox("Cheats") {
                        VStack(spacing: 8) {
                            HStack {
                                TextField("Game Genie / PAR", text: $cheatInput)
                                    .textFieldStyle(.roundedBorder)
                                Button("Add") {
                                    emulator.addCheat(cheatInput)
                                    cheatInput = ""
                                }
                                .disabled(cheatInput.isEmpty)
                            }
                            
                            List(emulator.activeCheats, id: \.self) { cheat in
                                Text(cheat)
                                    .font(.caption2)
                                    .monospaced()
                            }
                            .frame(height: 100)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                        }
                        .padding(4)
                    }
                    
                    // Debug
                    GroupBox("Debug") {
                        VStack(alignment: .leading, spacing: 6) {
                            Button("Test: Color Bars") { emulator.testPattern(.colorBars) }
                            Button("Test: Grid") { emulator.testPattern(.grid) }
                            Button("Test: Audio Tone") { emulator.testPattern(.audio) }
                            Toggle("CPU Log", isOn: Binding(
                                get: { emulator.cpuLoggingEnabled },
                                set: { emulator.toggleLogging($0) }
                            ))
                        }
                        .font(.caption)
                        .padding(4)
                    }
                    
                    Spacer()
                }
                .padding()
                .frame(width: 280)
                .background(Color(NSColor.windowBackgroundColor))
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType.data], // Accepts generic data to cover .sfc/.smc types
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                emulator.loadROM(from: url)
            }
        }
    }
    
    // MARK: - Helpers
    
    private func loadDroppedROM(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (item, error) in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            
            DispatchQueue.main.async {
                emulator.loadROM(from: url)
            }
        }
    }
}

// MARK: - Keyboard Handling
// This invisible view hooks into the macOS responder chain to grab key events
struct KeyboardGlobalHandler: NSViewRepresentable {
    let emulator: SNESSystem
    
    func makeNSView(context: Context) -> InputView {
        let view = InputView()
        view.emulator = emulator
        return view
    }
    
    func updateNSView(_ nsView: InputView, context: Context) {
        nsView.emulator = emulator
    }
    
    class InputView: NSView {
        weak var emulator: SNESSystem?
        
        override var acceptsFirstResponder: Bool { true }
        
        override func viewDidMoveToWindow() {
            // Auto-focus this view so it catches keys immediately
            window?.makeFirstResponder(self)
        }
        
        override func keyDown(with event: NSEvent) {
            guard !event.isARepeat else { return }
            emulator?.handleKeyDown(event.keyCode)
        }
        
        override func keyUp(with event: NSEvent) {
            emulator?.handleKeyUp(event.keyCode)
        }
        
        // Allow system shortcuts (like Cmd+Q) to pass through
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            return false
        }
    }
}
