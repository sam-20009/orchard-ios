import Foundation

// Analisa metadados de pacotes sem executar binários ou bibliotecas de terceiros.
enum PackageType: String, Codable {
    case androidAPK = "APK Android"
    case iphoneIPA = "IPA iOS"
    case phoneXR = "Pacote PXR"
    case archive = "Arquivo ZIP"
    case invalid = "Arquivo inválido"
}

struct PackageReport: Codable, Equatable {
    let type: PackageType
    let hasOpenXR: Bool
    let hasIOSPayload: Bool
    let details: [String]
    // Apps instalados podem ser abertos pelo sistema, mas não executados de dentro de outro app.
    var executableInsideApp: Bool { false }
}

enum PackageAnalyzer {
    enum AnalyzerError: Error { case unreadable, invalidZIP, unsupported }

    static func inspect(_ url: URL) throws -> PackageReport {
        let ext = url.pathExtension.lowercased()
        guard ["apk", "ipa", "pxr", "zip"].contains(ext) else { throw AnalyzerError.unsupported }
        // A leitura mapeada evita cópias extensas de dados na memória.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let names = zipEntryNames(data), !names.isEmpty else { throw AnalyzerError.invalidZIP }
        let normalized = names.map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 }
        let hasManifest = normalized.contains("AndroidManifest.xml")
        let hasLoader = normalized.contains { $0.hasSuffix("/libopenxr_loader.so") }
        let hasOculus = normalized.contains { $0.localizedCaseInsensitiveContains("oculus") }
        let hasIPA = normalized.contains { $0.hasPrefix("Payload/") && $0.contains(".app/") }
        let hasIOSPayload = normalized.contains("payload/ios/game.ipa")
        let hasAndroidPayload = normalized.contains("payload/android/game.apk")
        let isPXR = normalized.contains("manifest.json") && ext == "pxr"
        let hasSource = normalized.contains("source/ProjectSettings/ProjectVersion.txt")

        switch ext {
        case "apk":
            guard hasManifest else { throw AnalyzerError.invalidZIP }
            return PackageReport(type: .androidAPK, hasOpenXR: hasLoader || hasOculus,
                hasIOSPayload: false,
                details: ["Pacote Android identificado", hasLoader ? "Biblioteca OpenXR encontrada" : "Sem loader OpenXR identificado", "APK não executa nativamente no iOS", "Para jogar, é necessário portar o código-fonte para iOS/Metal"])
        case "ipa":
            guard hasIPA else { throw AnalyzerError.invalidZIP }
            return PackageReport(type: .iphoneIPA, hasOpenXR: false, hasIOSPayload: true,
                details: ["Aplicativo iOS identificado", "Instalação e assinatura ocorrem fora do Aether XR", "O iOS não permite executar outro IPA dentro deste app"])
        case "pxr":
            guard isPXR else { throw AnalyzerError.invalidZIP }
            return PackageReport(type: .phoneXR, hasOpenXR: hasAndroidPayload || hasIOSPayload || hasSource,
                hasIOSPayload: hasIOSPayload,
                details: [hasSource ? "Projeto Unity incluído" : "Pacote PXR identificado", hasAndroidPayload ? "APK Android incluído" : "Nenhum APK incluído", hasIOSPayload ? "IPA para iOS incluído" : "Nenhum IPA para iOS incluído", "Aether XR pode catalogar, mas não executar o pacote diretamente"])
        default:
            return PackageReport(type: .archive, hasOpenXR: hasLoader || hasOculus,
                hasIOSPayload: hasIPA || hasIOSPayload,
                details: ["ZIP válido", "Importado apenas para inspeção"])
        }
    }

    // Leitor mínimo, testável e sem dependências, do diretório central ZIP padrão.
    // ZIP64 e arquivos divididos intencionalmente não são aceitos.
    private static func zipEntryNames(_ data: Data) -> [String]? {
        guard data.count >= 22 else { return nil }
        func u16(_ p: Int) -> Int? {
            guard p >= 0 && p <= data.count - 2 else { return nil }
            return Int(data[p]) | (Int(data[p + 1]) << 8)
        }
        func u32(_ p: Int) -> Int? {
            guard p >= 0 && p <= data.count - 4 else { return nil }
            return Int(data[p]) | (Int(data[p + 1]) << 8) | (Int(data[p + 2]) << 16) | (Int(data[p + 3]) << 24)
        }
        let lowest = max(0, data.count - 65_557)
        var end: Int?
        for candidate in stride(from: data.count - 22, through: lowest, by: -1) {
            if u32(candidate) == 0x06054b50 { end = candidate; break }
        }
        guard let e = end,
              let entries = u16(e + 10),
              let directorySize = u32(e + 12),
              let directoryOffset = u32(e + 16),
              let commentLength = u16(e + 20),
              entries < 10_000,
              e + 22 + commentLength <= data.count,
              directoryOffset <= e,
              directorySize <= e - directoryOffset else { return nil }
        var cursor = directoryOffset
        var names: [String] = []
        for _ in 0..<entries {
            guard u32(cursor) == 0x02014b50,
                  let nameLength = u16(cursor + 28),
                  let extraLength = u16(cursor + 30),
                  let commentLength = u16(cursor + 32),
                  cursor <= e - 46,
                  let next = Optional(cursor + 46 + nameLength + extraLength + commentLength),
                  next <= e else { return nil }
            let start = cursor + 46
            guard let name = String(data: data[start..<(start + nameLength)], encoding: .utf8) else { return nil }
            names.append(name)
            cursor = next
        }
        return names
    }
}
