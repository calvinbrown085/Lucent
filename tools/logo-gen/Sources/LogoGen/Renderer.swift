import Foundation
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum Renderer {
    static func renderPNG(spec: OutputSpec, outputRoot: URL) throws {
        let view = LogoDesign(
            pixelSize: spec.pixelSize,
            composition: spec.composition,
            layer: spec.layer
        )
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: spec.pixelSize.width, height: spec.pixelSize.height)
        renderer.scale = 1.0

        guard let cgImage = renderer.cgImage else {
            throw RendererError.imageRenderingFailed(spec.relativePath)
        }

        let url = outputRoot.appending(path: spec.relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw RendererError.destinationCreationFailed(url.path)
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RendererError.destinationFinalizeFailed(url.path)
        }
    }
}

enum RendererError: Error, CustomStringConvertible {
    case imageRenderingFailed(String)
    case destinationCreationFailed(String)
    case destinationFinalizeFailed(String)

    var description: String {
        switch self {
        case .imageRenderingFailed(let path): "ImageRenderer returned nil cgImage for \(path)"
        case .destinationCreationFailed(let path): "Could not create CGImageDestination at \(path)"
        case .destinationFinalizeFailed(let path): "CGImageDestination finalize failed at \(path)"
        }
    }
}
