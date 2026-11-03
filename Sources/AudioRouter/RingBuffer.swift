import Synchronization

/// Lock-free stereo ring buffer.
/// - Producer: the Core Audio tap IOProc.
/// - Main consumer ("wet"): the source node that feeds the effect chain. It is a plain FIFO reader.
/// - Secondary consumer ("dry"): a source node that reads the *same* frames, `dryDelay` frames later,
///   so the dry signal stays sample-aligned with the wet signal after plug-in latency.
///   Both consumers render in the same engine cycle with the same sample time; the wet reader
///   publishes `offset = readPosition - sampleTime` each cycle and the dry reader uses it.
final class StereoRingBuffer: @unchecked Sendable {
    let capacity: Int
    private let mask: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let offset = Atomic<Int>(StereoRingBuffer.unsynced)
    private let inputPeak = PeakHold()
    private let delayFrames = Atomic<Int>(0)
    private var primed = false  // wet-consumer-only state

    private static let unsynced = Int.min

    /// Frames buffered before playback starts (latency vs. dropout safety).
    let targetFill: Int
    /// If more than this is buffered, the reader skips ahead to keep latency low.
    let maxFill: Int
    /// Already-played frames the writer must keep intact for the dry reader.
    let history: Int

    var maxDryDelay: Int { history - 8192 }

    init(capacity requested: Int = 1 << 17, targetFill: Int = 1024, maxFill: Int = 4096) {
        var cap = 1
        while cap < requested { cap <<= 1 }
        capacity = cap
        mask = cap - 1
        history = cap / 2
        left = .allocate(capacity: cap)
        right = .allocate(capacity: cap)
        left.initialize(repeating: 0, count: cap)
        right.initialize(repeating: 0, count: cap)
        self.targetFill = targetFill
        self.maxFill = maxFill
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    /// Call only while neither producer nor consumers are running.
    func reset() {
        writeIndex.store(0, ordering: .sequentiallyConsistent)
        readIndex.store(0, ordering: .sequentiallyConsistent)
        offset.store(Self.unsynced, ordering: .sequentiallyConsistent)
        left.update(repeating: 0, count: capacity)
        right.update(repeating: 0, count: capacity)
        primed = false
    }

    /// Delay of the dry signal relative to the wet input, in frames (= total plug-in latency).
    func setDryDelay(_ frames: Int) {
        delayFrames.store(max(0, min(frames, maxDryDelay)), ordering: .relaxed)
    }

    /// Peak absolute input sample since the last call.
    func takeInputPeak() -> Float {
        inputPeak.take()
    }

    // MARK: Producer

    private func freeSpace(_ w: Int) -> Int {
        let r = readIndex.load(ordering: .acquiring)
        return capacity - history - (w - r)
    }

    private func notePeak(_ peak: Float) { inputPeak.note(peak) }

    /// Writes frames from (possibly interleaved) channel pointers; `stride` is in samples.
    func write(left l: UnsafePointer<Float>, leftStride ls: Int,
               right rt: UnsafePointer<Float>, rightStride rs: Int, frames: Int) {
        let w = writeIndex.load(ordering: .relaxed)
        let n = min(frames, freeSpace(w))
        guard n > 0 else { return }
        var peak: Float = 0
        for i in 0..<n {
            let idx = (w + i) & mask
            let a = l[i * ls], b = rt[i * rs]
            left[idx] = a
            right[idx] = b
            peak = max(peak, abs(a), abs(b))
        }
        writeIndex.store(w + n, ordering: .releasing)
        notePeak(peak)
    }

    // MARK: Consumers

    private func copy(from pos: Int, _ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>, _ n: Int) {
        for i in 0..<n {
            let idx = (pos + i) & mask
            outL[i] = left[idx]
            outR[i] = right[idx]
        }
    }

    /// Wet reader. `sampleTime` is the render timestamp's sample time.
    func read(sampleTime: Int, left outL: UnsafeMutablePointer<Float>, right outR: UnsafeMutablePointer<Float>,
              frames n: Int) -> Bool {
        let w = writeIndex.load(ordering: .acquiring)
        var r = readIndex.load(ordering: .relaxed)
        var available = w - r

        if available > maxFill {          // too much latency accumulated: skip ahead
            r = w - targetFill
            available = targetFill
        }
        if !primed {
            guard available >= targetFill else {
                outL.update(repeating: 0, count: n)
                outR.update(repeating: 0, count: n)
                offset.store(Self.unsynced, ordering: .releasing)
                readIndex.store(r, ordering: .releasing)
                return false
            }
            primed = true
        }

        offset.store(r - sampleTime, ordering: .releasing)
        let toRead = min(available, n)
        copy(from: r, outL, outR, toRead)
        if toRead < n {                     // underflow: pad and re-prime
            (outL + toRead).update(repeating: 0, count: n - toRead)
            (outR + toRead).update(repeating: 0, count: n - toRead)
            primed = false
        }
        readIndex.store(r + toRead, ordering: .releasing)
        return toRead > 0
    }

    /// Dry reader: the same frames the wet reader gets for this `sampleTime`, delayed by `dryDelay`.
    func readDry(sampleTime: Int, left outL: UnsafeMutablePointer<Float>, right outR: UnsafeMutablePointer<Float>,
                 frames n: Int) -> Bool {
        let off = offset.load(ordering: .acquiring)
        let w = writeIndex.load(ordering: .acquiring)
        let r = readIndex.load(ordering: .acquiring)
        if off != Self.unsynced {
            let pos = sampleTime + off - delayFrames.load(ordering: .relaxed)
            if pos >= r - history + n, pos + n <= w {
                copy(from: pos, outL, outR, n)
                return true
            }
        }
        outL.update(repeating: 0, count: n)
        outR.update(repeating: 0, count: n)
        return false
    }
}

/// Thread-safe "max since last read" holder for metering.
final class PeakHold: @unchecked Sendable {
    private let bits = Atomic<UInt32>(0)

    func note(_ peak: Float) {
        // Non-negative floats order the same as their bit patterns.
        let new = peak.bitPattern
        var current = bits.load(ordering: .relaxed)
        while new > current {
            let (exchanged, original) = bits.compareExchange(expected: current, desired: new, ordering: .relaxed)
            if exchanged { break }
            current = original
        }
    }

    func take() -> Float { Float(bitPattern: bits.exchange(0, ordering: .relaxed)) }
}
