import Foundation

struct OutputSpec {
    let relativePath: String
    let pixelSize: CGSize
    let composition: Composition
    let layer: Layer
}

enum Outputs {
    private static let assetsRoot = "Lucent/Lucent/Assets.xcassets"
    private static let brandassets = "\(assetsRoot)/App Icon & Top Shelf Image.brandassets"

    static let all: [OutputSpec] = parallaxIcon + appStoreIcon + topShelf + topShelfWide + iosAppIcon

    private static let parallaxIcon: [OutputSpec] = {
        let layers: [(name: String, layer: Layer)] = [
            ("Front", .front), ("Middle", .middle), ("Back", .back)
        ]
        return layers.flatMap { spec in
            [
                OutputSpec(
                    relativePath: "\(brandassets)/App Icon.imagestack/\(spec.name).imagestacklayer/Content.imageset/\(spec.name).png",
                    pixelSize: CGSize(width: 400, height: 240),
                    composition: .icon,
                    layer: spec.layer
                ),
                OutputSpec(
                    relativePath: "\(brandassets)/App Icon.imagestack/\(spec.name).imagestacklayer/Content.imageset/\(spec.name)@2x.png",
                    pixelSize: CGSize(width: 800, height: 480),
                    composition: .icon,
                    layer: spec.layer
                )
            ]
        }
    }()

    private static let appStoreIcon: [OutputSpec] = {
        let layers: [(name: String, layer: Layer)] = [
            ("Front", .front), ("Middle", .middle), ("Back", .back)
        ]
        return layers.map { spec in
            OutputSpec(
                relativePath: "\(brandassets)/App Icon - App Store.imagestack/\(spec.name).imagestacklayer/Content.imageset/\(spec.name).png",
                pixelSize: CGSize(width: 1280, height: 768),
                composition: .icon,
                layer: spec.layer
            )
        }
    }()

    private static let topShelf: [OutputSpec] = [
        OutputSpec(
            relativePath: "\(brandassets)/Top Shelf Image.imageset/top-shelf-image.png",
            pixelSize: CGSize(width: 1920, height: 720),
            composition: .topShelf,
            layer: .flat
        ),
        OutputSpec(
            relativePath: "\(brandassets)/Top Shelf Image.imageset/top-shelf-image@2x.png",
            pixelSize: CGSize(width: 3840, height: 1440),
            composition: .topShelf,
            layer: .flat
        )
    ]

    private static let topShelfWide: [OutputSpec] = [
        OutputSpec(
            relativePath: "\(brandassets)/Top Shelf Image Wide.imageset/top-shelf-image-wide.png",
            pixelSize: CGSize(width: 2320, height: 720),
            composition: .topShelfWide,
            layer: .flat
        ),
        OutputSpec(
            relativePath: "\(brandassets)/Top Shelf Image Wide.imageset/top-shelf-image-wide@2x.png",
            pixelSize: CGSize(width: 4640, height: 1440),
            composition: .topShelfWide,
            layer: .flat
        )
    ]

    private static let iosAppIcon: [OutputSpec] = [
        OutputSpec(
            relativePath: "\(assetsRoot)/AppIcon.appiconset/AppIcon.png",
            pixelSize: CGSize(width: 1024, height: 1024),
            composition: .icon,
            layer: .flat
        )
    ]
}
