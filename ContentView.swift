import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var snes = SNESSystem()
    @State private var isImporting: Bool = false
    @State private var cheatCode: String = ""
    @State private var isLogging: Bool = false
    
    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black
                MetalView(renderer: snes.renderer)
                    .aspectRatio(8.0/7.0, contentMode: .fit)
            }
            .frame(minWidth: 512, minHeight: 448)
            .background(KeyboardHandler(snes: snes))
            
            VStack(alignment: .leading, spacing: 10) {
                Text("SwiftSNES Final")
                    .font(.headline)
                    .padding(.top)
                
                if snes.isTurbo {
                    Text("TURBO ENABLED")
                        .font(.caption)
                        .bold()
                        .foregroundColor(.red)
                }
                
                Divider()
                
                Group {
                    Text("Controls").bold()
                    HStack {
                        if snes.isRunning {
                            Button(action: { snes.stopEmulation() }) {
                                Label("Stop", systemImage: "pause.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button(action: { snes.startEmulation() }) {
                                Label("Run", systemImage: "play.fill")
                            }
                            .disabled(!snes.cartridgeLoaded)
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    HStack {
                        Button("Quick Save") {
                            if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("state.sav") {
                                snes.saveState(to: url)
                            }
                        }
                        Button("Quick Load") {
                            if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("state.sav") {
                                snes.loadState(from: url)
                            }
                        }
                    }
                }
                
                Divider()
                
                Group {
                    Text("Debug").bold()
                    HStack {
                        Button("Test Video") { snes.runVideoTest() }
                        Button("Test Hires") { snes.runHiresTest() }
                        Button("Color Bars") { snes.runColorBarsTest() }
                        Button("Grid") { snes.runGridTest() }
                        Button("Test Audio") { snes.runAudioTest() }
                    }
                    Toggle("Log CPU", isOn: $isLogging)
                        .onChange(of: isLogging) { _, newValue in
                            snes.toggleLogging(newValue)
                        }
                        .font(.caption)
                }
                
                Divider()
                
                Group {
                    Text("Cheats").bold()
                    HStack {
                        TextField("Code", text: $cheatCode)
                        Button("+") {
                            snes.bus.cheatEngine.addCheat(code: cheatCode)
                            cheatCode = ""
                        }
                    }
                    List(snes.bus.cheatEngine.cheats, id: \.address) { cheat in
                        Text(cheat.description).font(.caption)
                    }
                    .frame(height: 100)
                }
                
                Spacer()
                
                HStack {
                    Button("Load ROM") { isImporting = true }
                    Button(action: { snes.reset() }) {
                        Image(systemName: "arrow.counterclockwise")
                    }
                }
                Text(snes.statusMessage).font(.caption).foregroundColor(.gray)
            }
            .padding()
            .frame(width: 300)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let selectedFile: URL = try result.get().first else { return }
                if selectedFile.startAccessingSecurityScopedResource() {
                    let data = try Data(contentsOf: selectedFile)
                    snes.loadRom(data: data)
                    selectedFile.stopAccessingSecurityScopedResource()
                }
            } catch {
                print("Error loading file: \(error.localizedDescription)")
            }
        }
    }
}

struct RegisterView: View {
    let l: String
    let v: UInt16
    var body: some View {
        Text("\(l): \(String(format: "%04X", v))")
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct KeyboardHandler: NSViewRepresentable {
    var snes: SNESSystem
    func makeNSView(context: Context) -> NSView {
        let view = KeyView()
        view.snes = snes
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

class KeyView: NSView {
    weak var snes: SNESSystem?
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) { snes?.handleKey(code: event.keyCode, isDown: true) }
    override func keyUp(with event: NSEvent) { snes?.handleKey(code: event.keyCode, isDown: false) }
}
