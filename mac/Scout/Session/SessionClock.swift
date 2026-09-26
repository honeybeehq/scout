import AVFoundation
import ScoutCore

nonisolated struct SessionClock: Sendable {
    let originHostTime: UInt64
    let originDate: Date

    init() {
        originHostTime = mach_absolute_time()
        originDate = Date()
    }

    var now: SessionTime {
        seconds(atHostTime: mach_absolute_time())
    }

    func seconds(atHostTime hostTime: UInt64) -> SessionTime {
        AVAudioTime.seconds(forHostTime: hostTime) - AVAudioTime.seconds(forHostTime: originHostTime)
    }

    func seconds(at date: Date) -> SessionTime {
        date.timeIntervalSince(originDate)
    }
}
