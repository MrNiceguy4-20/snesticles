import AVFoundation
import os

class AudioDriver {
    var engine: AVAudioEngine
    var sourceNode: AVAudioSourceNode!
    var isRunning = false
    
    private let capacity = 32768
    private var buffer: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    
    // We use a UnfairLock which is efficient for high-contention, low-latency scenarios
    private let lock = OSAllocatedUnfairLock()
    
    init() {
        buffer = [Float](repeating: 0, count: capacity)
        engine = AVAudioEngine()
        let format = engine.outputNode.inputFormat(forBus: 0)
        
        sourceNode = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList in
            guard let self = self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let bufL = UnsafeMutableBufferPointer<Float>(abl[0])
            let bufR = (abl.count > 1) ? UnsafeMutableBufferPointer<Float>(abl[1]) : nil
            
            // Critical Section: Keep it as short as possible
            self.lock.lock()
            let available = (self.writeIndex + self.capacity - self.readIndex) % self.capacity
            
            // If we don't have enough data, fill with silence and return immediately
            // This prevents the audio thread from blocking too long
            if available < Int(frameCount) * 2 { // *2 for stereo
                for i in 0..<Int(frameCount) {
                    bufL[i] = 0
                    bufR?[i] = 0
                }
                self.lock.unlock()
                return noErr
            }
            
            for i in 0..<Int(frameCount) {
                let valL = self.buffer[self.readIndex]
                self.readIndex = (self.readIndex + 1) % self.capacity
                
                let valR = self.buffer[self.readIndex]
                self.readIndex = (self.readIndex + 1) % self.capacity
                
                bufL[i] = valL
                bufR?[i] = valR
            }
            self.lock.unlock()
            
            return noErr
        }
        
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
    }
    
    func start() {
        if isRunning { return }
        do {
            try engine.start()
            isRunning = true
        } catch {
            print("Audio Engine Start Error: \(error)")
        }
    }
    
    func playTestTone() {
        lock.lock()
        defer { lock.unlock() }
        
        let freq = 440.0
        let rate = 44100.0
        for i in 0..<1024 {
            let sample = Float(sin(2.0 * .pi * freq * Double(i) / rate)) * 0.5
            let nextIndex = (writeIndex + 1) % capacity
            if nextIndex != readIndex {
                buffer[writeIndex] = sample
                writeIndex = (writeIndex + 1) % capacity
                buffer[writeIndex] = sample
                writeIndex = (writeIndex + 1) % capacity
            }
        }
    }
    
    func queueSamples(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        
        for sample in samples {
            let nextIndex = (writeIndex + 1) % capacity
            if nextIndex != readIndex {
                buffer[writeIndex] = sample
                writeIndex = nextIndex
            }
        }
    }
}
