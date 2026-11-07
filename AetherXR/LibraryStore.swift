import Foundation

struct LibraryEntry: Codable, Identifiable {
    let id: UUID
    let name: String
    let storedName: String
    let importedAt: Date
    let report: PackageReport
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var entries: [LibraryEntry] = []
    @Published var notification: String? = nil
    private let fm = FileManager.default

    private var directory: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AetherLibrary", isDirectory: true)
    }
    private var index: URL { directory.appendingPathComponent("index.json") }

    init() {
        if let bytes = try? Data(contentsOf: index),
           let stored = try? JSONDecoder().decode([LibraryEntry].self, from: bytes) {
            entries = stored
        }
    }

    func add(_ externalURL: URL) {
        let scoped = externalURL.startAccessingSecurityScopedResource()
        defer { if scoped { externalURL.stopAccessingSecurityScopedResource() } }
        do {
            guard externalURL.isFileURL else { throw ImportError.notLocal }
            let report = try PackageAnalyzer.inspect(externalURL)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let storedName = UUID().uuidString + "." + externalURL.pathExtension.lowercased()
            try fm.copyItem(at: externalURL, to: directory.appendingPathComponent(storedName))
            entries.insert(LibraryEntry(id: UUID(), name: externalURL.lastPathComponent,
                  storedName: storedName, importedAt: Date(), report: report), at: 0)
            try persist()
            notification = "Arquivo importado com sucesso."
        } catch {
            notification = "Não foi possível importar: \(error.localizedDescription)"
        }
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            try? fm.removeItem(at: directory.appendingPathComponent(entries[index].storedName))
        }
        entries.remove(atOffsets: offsets)
        try? persist()
    }

    private func persist() throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: index, options: .atomic)
    }

    private enum ImportError: LocalizedError {
        case notLocal
        var errorDescription: String? { "Selecione um arquivo armazenado no dispositivo." }
    }
}
