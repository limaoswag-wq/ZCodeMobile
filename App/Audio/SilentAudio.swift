import AVFoundation

enum SilentAudio {
    static let shared = Player()

    final class Player {
        private var player: AVAudioPlayer?

        func start() {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
            if player == nil {
                player = try? AVAudioPlayer(data: Self.tinyWAV)
                player?.numberOfLoops = -1
                player?.volume = 0
            }
            player?.play()
        }

        func stop() {
            player?.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        private static let tinyWAV: Data = {
            let samples = [UInt8](repeating: 128, count: 1600)
            var data = Data()
            func ascii(_ s: String) { data.append(contentsOf: s.utf8) }
            func u16(_ v: UInt16) {
                var le = v.littleEndian
                data.append(Data(bytes: &le, count: 2))
            }
            func u32(_ v: UInt32) {
                var le = v.littleEndian
                data.append(Data(bytes: &le, count: 4))
            }
            ascii("RIFF")
            u32(UInt32(36 + samples.count))
            ascii("WAVE")
            ascii("fmt ")
            u32(16)
            u16(1)
            u16(1)
            u32(8000)
            u32(8000)
            u16(1)
            u16(8)
            ascii("data")
            u32(UInt32(samples.count))
            data.append(contentsOf: samples)
            return data
        }()
    }
}
