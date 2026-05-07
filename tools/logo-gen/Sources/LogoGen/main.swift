import Foundation

@MainActor
func run() throws {
    let repoRoot = try resolveRepoRoot()
    print("[logogen] repo root: \(repoRoot.path)")

    let specs = Outputs.all
    print("[logogen] generating \(specs.count) PNG(s)")

    for spec in specs {
        try Renderer.renderPNG(spec: spec, outputRoot: repoRoot)
        print("[logogen] wrote \(spec.relativePath) (\(Int(spec.pixelSize.width))x\(Int(spec.pixelSize.height)))")
    }

    print("[logogen] done")
}

@MainActor
func resolveRepoRoot() throws -> URL {
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let marker = "Lucent/Lucent.xcodeproj"
    while dir.path != "/" {
        let candidate = dir.appending(path: marker)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return dir
        }
        dir = dir.deletingLastPathComponent()
    }
    throw RunError.repoRootNotFound
}

enum RunError: Error, CustomStringConvertible {
    case repoRootNotFound

    var description: String {
        switch self {
        case .repoRootNotFound:
            return "Could not find repo root (looking upward for Lucent/Lucent.xcodeproj). Run from inside the Lucent repo."
        }
    }
}

do {
    try MainActor.assumeIsolated {
        try run()
    }
} catch {
    FileHandle.standardError.write(Data("[logogen] error: \(error)\n".utf8))
    exit(1)
}
