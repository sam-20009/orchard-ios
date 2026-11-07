import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var importFile = false
    @State private var showVR = false
    @State private var showHands = false
    @State private var selectedTab = 0
    @AppStorage("aether.ipd") private var ipd = 64.0
    @AppStorage("aether.motion") private var motionEnabled = true
    @AppStorage("aether.sensitivity") private var sensitivity = 1.0
    @AppStorage("aether.vignette") private var vignette = true
    @AppStorage("aether.stereo") private var stereo = true
    @AppStorage("aether.showGrid") private var showGrid = true

    private var fileTypes: [UTType] {
        [.data, .zip] + ["apk", "ipa", "pxr", "zip"].compactMap { UTType(filenameExtension: $0) }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { home }
                .tabItem { Label("Início", systemImage: "house.fill") }.tag(0)
            NavigationStack { libraryView }
                .tabItem { Label("Biblioteca", systemImage: "square.stack.fill") }.tag(1)
            NavigationStack { trackingView }
                .tabItem { Label("Mãos", systemImage: "hand.raised.fill") }.tag(2)
            NavigationStack { settingsView }
                .tabItem { Label("Ajustes", systemImage: "gearshape.fill") }.tag(3)
        }
        .tint(AetherTheme.purple)
        .fileImporter(isPresented: $importFile, allowedContentTypes: fileTypes) { result in
            switch result {
            case .success(let url): library.add(url)
            case .failure(let error): library.notification = error.localizedDescription
            }
        }
        .alert("Aether XR", isPresented: Binding(get: { library.notification != nil }, set: { if !$0 { library.notification = nil } })) {
            Button("OK") { library.notification = nil }
        } message: { Text(library.notification ?? "") }
        .fullScreenCover(isPresented: $showVR) {
            StereoExperience(ipd: ipd, motionEnabled: motionEnabled, sensitivity: sensitivity,
                             vignette: vignette, stereo: stereo, showGrid: showGrid)
        }
        .fullScreenCover(isPresented: $showHands) { HandTrackingScreen() }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AetherHeader()
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 26)
                        .fill(LinearGradient(colors: [AetherTheme.purple.opacity(0.75), AetherTheme.card, .black],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "visionpro")
                        .resizable().scaledToFit().frame(width: 160, height: 90)
                        .foregroundStyle(.white.opacity(0.25)).frame(maxWidth: .infinity)
                        .offset(y: -40)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Seu portal para o XR").font(.title2.bold())
                        Text("Visor estereoscópico experimental com sensores do iPhone.")
                            .font(.footnote).foregroundStyle(.white.opacity(0.75))
                    }.padding(22)
                }.frame(height: 218)
                primaryButton("Iniciar visor VR", icon: "play.fill") { showVR = true }
                featureButton("Biblioteca", subtitle: "Arquivos, aplicativos e pacotes", icon: "square.stack.3d.up.fill") { selectedTab = 1 }
                featureButton("Importar aplicativo", subtitle: "APK, IPA, PXR ou ZIP", icon: "square.and.arrow.down.fill") { importFile = true }
                featureButton("Rastreamento das mãos", subtitle: "Detecção com a câmera e Vision", icon: "hand.raised.fingers.spread.fill") { showHands = true }
                featureButton("Configurações", subtitle: "Visor, sensores e conforto", icon: "slider.horizontal.3") { selectedTab = 3 }
                Text("Versão 0.2 • Mãos no visor VR • Código aberto")
                    .frame(maxWidth: .infinity).font(.caption2).foregroundStyle(AetherTheme.textMuted)
            }.padding(18)
        }.background(AetherTheme.background).navigationBarHidden(true)
    }

    private var libraryView: some View {
        List {
            Section {
                Button { importFile = true } label: { Label("Importar APK, IPA, PXR ou ZIP", systemImage: "square.and.arrow.down") }
            } footer: {
                Text("O Aether XR analisa e guarda os arquivos. APKs não podem ser executados no iOS sem um porte do jogo.")
            }
            if library.entries.isEmpty {
                ContentUnavailableView("Biblioteca vazia", systemImage: "shippingbox", description: Text("Importe um pacote para analisar os recursos XR."))
                    .listRowBackground(Color.clear)
            }
            Section("Arquivos") {
                ForEach(library.entries) { entry in
                    NavigationLink {
                        PackageDetails(entry: entry)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: entry.report.type == .androidAPK ? "apps.iphone" : "cube.transparent")
                                .font(.title3).foregroundStyle(AetherTheme.purple)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.name).lineLimit(1)
                                Text(entry.report.type.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.onDelete(perform: library.delete)
            }
        }.scrollContentBackground(.hidden).background(AetherTheme.background)
        .navigationTitle("Biblioteca")
    }

    private var trackingView: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "hand.raised.fingers.spread")
                    .font(.system(size: 74)).foregroundStyle(AetherTheme.gradient)
                    .padding(.top, 35)
                Text("Rastreamento de mãos").font(.title2.bold())
                Text("Visualize os pontos reconhecidos pela câmera traseira. O modo demonstra a detecção 2D; ainda não controla jogos externos.")
                    .multilineTextAlignment(.center).foregroundStyle(AetherTheme.textMuted)
                primaryButton("Abrir câmera de mãos", icon: "camera.fill") { showHands = true }
                AetherCard {
                    Label("Até duas mãos por quadro", systemImage: "hand.raised")
                    Text("Executado localmente usando Vision, sem enviar vídeo à internet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(22)
        }.background(AetherTheme.background).navigationTitle("Mãos")
    }

    private var settingsView: some View {
        Form {
            Section("Visor (VR)") {
                Toggle("Tela dividida", isOn: $stereo)
                VStack(alignment: .leading) {
                    HStack { Text("Distância interpupilar"); Spacer(); Text("\(Int(ipd)) mm").foregroundStyle(.secondary) }
                    Slider(value: $ipd, in: 55...72, step: 1)
                }
                Toggle("Grade de referência", isOn: $showGrid)
                Toggle("Vinheta de conforto", isOn: $vignette)
            }
            Section("Movimento") {
                Toggle("Usar giroscópio", isOn: $motionEnabled)
                VStack(alignment: .leading) {
                    HStack { Text("Sensibilidade"); Spacer(); Text(String(format: "%.1fx", sensitivity)).foregroundStyle(.secondary) }
                    Slider(value: $sensitivity, in: 0.5...1.5, step: 0.1)
                }
            }
            Section("Compatibilidade") {
                LabeledContent("Plataforma", value: "iOS 17 ou superior")
                LabeledContent("Renderização", value: "SceneKit")
                LabeledContent("Rastreamento", value: "CoreMotion / Vision")
                Text("Compatibilidade OpenXR, distorção óptica calibrada e execução de APKs não implementadas.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sobre") {
                LabeledContent("Aplicativo", value: "Aether XR 0.2")
                Text("Projeto independente inspirado nas funções públicas do PhoneXR. Não inclui código ou logotipos do projeto original.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.scrollContentBackground(.hidden).background(AetherTheme.background)
        .navigationTitle("Configurações")
    }

    private func primaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                Text(title).fontWeight(.semibold)
                Spacer()
                Image(systemName: "chevron.right")
            }.padding(16).foregroundStyle(.white)
                .background(AetherTheme.gradient, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }

    private func featureButton(_ title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            AetherCard {
                HStack(spacing: 14) {
                    Image(systemName: icon).font(.title2).frame(width: 33)
                        .foregroundStyle(AetherTheme.purple)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline)
                        Text(subtitle).font(.caption).foregroundStyle(AetherTheme.textMuted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(AetherTheme.textMuted)
                }.foregroundStyle(.white)
            }
        }.buttonStyle(.plain)
    }
}

private struct PackageDetails: View {
    let entry: LibraryEntry
    var body: some View {
        List {
            Section("Identificação") {
                LabeledContent("Arquivo", value: entry.name)
                LabeledContent("Tipo", value: entry.report.type.rawValue)
                LabeledContent("OpenXR detectado", value: entry.report.hasOpenXR ? "Sim" : "Não")
            }
            Section("Diagnóstico") {
                ForEach(entry.report.details, id: \.self) { detail in
                    Label(detail, systemImage: "info.circle")
                }
            }
            Section {
                Label("Execução direta indisponível", systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
            } footer: {
                Text("A biblioteca não emula Android, não instala IPAs e não permite que apps executem binários de outros apps.")
            }
        }.navigationTitle(entry.name).navigationBarTitleDisplayMode(.inline)
    }
}
