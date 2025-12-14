//
//  AudioDriver.swift
//  snits
//
//  Created by kevin on 2025-12-05.
//

import AVFoundation
import os.log

final class AudioDriver {
    // Core Audio Engine
    private let engine = AVAudioEngine()
    private let mixer = AVAudioMixerNode()
    private var sourceNode: AVAudioSourceNode!
    
    // Audio State
    private let sampleRate: Double = 32040.0 // Native SNES rate
    private let channels: UInt32 = 2
    private var isRunning = false
    
    // Ring Buffer (Thread-Safe decoupling)
    // Size = 8192 floats (~128ms of audio), enough to absorb jitter without lag
    private let bufferSize = 8192
    private var buffer: [Float]
    private var writeIndex = 0
    private var readIndex = 0
    private var availableCount = 0
    
    // Concurrency
    private let lock = NSLock()
    
    init() {
        self.buffer = [Float](repeating: 0.0, count: bufferSize)
        setupAudioGraph()
    }
    
    deinit {
        stop()
    }
    
    // MARK: - Setup
    
    private func setupAudioGraph() {
        // 1. Define the SNES native format (32kHz, Stereo, Non-Interleaved internally for Node)
        // We use interleaved: false for the node format because AVAudioSourceNode usually provides separate pointers.
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
        
        // 2. Create the Source Node (The Callback)
        sourceNode = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            return self.renderBlock(frameCount: Int(frameCount), bufferList: audioBufferList)
        }
        
        // 3. Attach and Connect
        engine.attach(sourceNode)
        engine.attach(mixer)
        
        // Connect Source -> Mixer (Engine handles resampling from 32k -> 48k automatically here)
        engine.connect(sourceNode, to: mixer, format: inputFormat)
        
        // Connect Mixer -> Output
        engine.connect(mixer, to: engine.mainMixerNode, format: nil)
        
        // 4. Initial settings
        mixer.outputVolume = 0.8 // Default volume
        
        // 5. Start
        start()
    }
    
    private func start() {
        do {
            try engine.start()
            isRunning = true
            os_log("Audio Engine started at 32040Hz", type: .info)
        } catch {
            os_log("Failed to start audio engine: %@", type: .error, error.localizedDescription)
        }
    }
    
    func stop() {
        engine.stop()
        isRunning = false
    }
    
    // MARK: - External Interface (Called by SNESSystem)
    
    /// Queue interleaved samples (L, R, L, R...) from the DSP
    func queueSamples(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        
        lock.lock()
        defer { lock.unlock() }
        
        // If buffer is too full, we must drop samples to prevent lag (latency catch-up)
        // This usually happens if emulation is running too fast (turbo mode)
        if availableCount + samples.count > bufferSize {
            // Hard reset buffer to sync if we are way off
            readIndex = 0
            writeIndex = 0
            availableCount = 0
        }
        
        for sample in samples {
            buffer[writeIndex] = sample
            writeIndex = (writeIndex + 1) % bufferSize
            availableCount += 1
        }
    }
    
    func setVolume(_ volume: Float) {
        mixer.outputVolume = max(0.0, min(1.0, volume))
    }
    
    // MARK: - Render Loop (High Priority Thread)
    
    private func renderBlock(frameCount: Int, bufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
            // FIXED: Explicitly construct the UnsafeMutableAudioBufferListPointer
            let ptr = UnsafeMutableAudioBufferListPointer(bufferList)
            
            guard ptr.count >= 2 else { return noErr }
            
            let leftChannel = UnsafeMutableBufferPointer<Float>(ptr[0])
            let rightChannel = UnsafeMutableBufferPointer<Float>(ptr[1])
            
            lock.lock()
        
        // Check if we have enough samples (Stereo = 2 floats per frame)
        // If we don't have enough, we output silence (Underflow protection)
        if availableCount < frameCount * 2 {
            // Underflow: Output silence
            for i in 0..<frameCount {
                leftChannel[i] = 0.0
                rightChannel[i] = 0.0
            }
            // Reset buffer pointers to resync
            availableCount = 0
            readIndex = writeIndex
            lock.unlock()
            return noErr
        }
        
        // Fill buffers
        for i in 0..<frameCount {
            // Read Left
            let lSample = buffer[readIndex]
            readIndex = (readIndex + 1) % bufferSize
            
            // Read Right
            let rSample = buffer[readIndex]
            readIndex = (readIndex + 1) % bufferSize
            
            leftChannel[i] = lSample
            rightChannel[i] = rSample
        }
        
        availableCount -= (frameCount * 2)
        lock.unlock()
        
        return noErr
    }
    
    // MARK: - Debug
    
    func playTestTone() {
        // Generate 0.5 seconds of A440 sine wave
        let toneCount = Int(sampleRate * 0.5)
        var tone = [Float]()
        for i in 0..<toneCount {
            let t = Double(i) / sampleRate
            let val = Float(sin(2.0 * .pi * 440.0 * t) * 0.5)
            tone.append(val) // L
            tone.append(val) // R
        }
        queueSamples(tone)
    }
}
