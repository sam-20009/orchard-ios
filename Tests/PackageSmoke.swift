import Foundation

@main
struct PackageSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Usage: smoke <fixtures directory>") }
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let kinds: [(String, PackageType, Bool, Bool)] = [
            ("valid.apk", .androidAPK, true, false),
            ("valid.ipa", .iphoneIPA, false, true),
            ("valid.pxr", .phoneXR, true, true),
            ("valid.zip", .archive, false, false)
        ]
        for (name, expectedType, openXR, iOS) in kinds {
            let report = try PackageAnalyzer.inspect(dir.appendingPathComponent(name))
            precondition(report.type == expectedType, "Wrong type for \(name)")
            precondition(report.hasOpenXR == openXR, "Wrong XR flag for \(name)")
            precondition(report.hasIOSPayload == iOS, "Wrong iOS flag for \(name)")
            precondition(!report.executableInsideApp, "Must not claim executable")
            print("PASS: \(name) → \(report.type.rawValue)")
        }
        do {
            _ = try PackageAnalyzer.inspect(dir.appendingPathComponent("broken.apk"))
            fatalError("Broken ZIP was accepted")
        } catch PackageAnalyzer.AnalyzerError.invalidZIP {
            print("PASS: arquivo ZIP inválido rejeitado")
        }
        print("5/5 tests passed")
    }
}
