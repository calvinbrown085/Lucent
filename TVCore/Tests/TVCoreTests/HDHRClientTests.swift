import Testing
import Foundation
@testable import TVCore

@Suite struct HDHRClientTests {

    @Test
    func decodesTunerStatusWithFullAndSparseEntries() throws {
        let json = """
        [{"Resource":"tuner0","VctNumber":"8.1","VctName":"WGAL-HD","Frequency":189000000,"SignalStrengthPercent":92,"SignalQualityPercent":88,"SymbolQualityPercent":100,"NetworkRate":9130000,"TargetIP":"192.168.1.10"},{"Resource":"tuner1"}]
        """
        let status = try JSONDecoder().decode([HDHRTunerStatus].self, from: Data(json.utf8))
        #expect(status.count == 2)

        let active = status[0]
        #expect(active.Resource == "tuner0")
        #expect(active.VctNumber == "8.1")
        #expect(active.VctName == "WGAL-HD")
        #expect(active.Frequency == 189_000_000)
        #expect(active.SignalStrengthPercent == 92)
        #expect(active.SignalQualityPercent == 88)
        #expect(active.SymbolQualityPercent == 100)
        #expect(active.NetworkRate == 9_130_000)
        #expect(active.TargetIP == "192.168.1.10")

        let idle = status[1]
        #expect(idle == HDHRTunerStatus(Resource: "tuner1"))
        #expect(idle.VctNumber == nil)
        #expect(idle.Frequency == nil)
        #expect(idle.TargetIP == nil)
    }

    @Test
    func tunerStatusIgnoresUnknownKeys() throws {
        let json = #"[{"Resource":"tuner0","Frequency":189000000,"SomeNewField":"x"}]"#
        let status = try JSONDecoder().decode([HDHRTunerStatus].self, from: Data(json.utf8))
        #expect(status.map(\.Resource) == ["tuner0"])
        #expect(status[0].Frequency == 189_000_000)
    }
}
