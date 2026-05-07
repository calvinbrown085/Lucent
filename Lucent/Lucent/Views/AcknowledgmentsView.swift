import SwiftUI

struct AcknowledgmentsView: View {
    @Environment(\.layoutMetrics) private var metrics

    private static let licenseText: String = {
        guard let url = Bundle.main.url(forResource: "LGPL-2.1", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "License text not bundled. See https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt"
        }
        return text
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("VLCKit / libVLC")
                        .font(.title2.bold())
                    Text("Lucent uses VLCKit (TVVLCKit on tvOS, MobileVLCKit on iOS / iPadOS), an unmodified build of libVLC by VideoLAN, to play HDHomeRun MPEG-TS streams that AVPlayer cannot decode.")
                    Text("Source: https://code.videolan.org/videolan/VLCKit")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("VLCKit is dynamically linked under the GNU Lesser General Public License version 2.1. The full license text is reproduced below.")
                    Text("Source for libVLC and VLCKit is available at the URL above. A copy on physical media is available on request from cab025@protonmail.com for the cost of distribution; this offer is valid for three years.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Text("GNU Lesser General Public License v2.1")
                    .font(.title3.bold())

                Text(Self.licenseText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(metrics.contentHorizontalPadding)
            .frame(maxWidth: metrics.contentMaxWidth ?? .infinity, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Acknowledgments")
    }
}
