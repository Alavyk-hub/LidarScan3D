import SwiftUI
import RealityKit

/// Režim 1: Apple Object Capture (LiDAR + fotky z 48MP kamery → fotogrammetrie přímo v iPhonu).
@MainActor
final class ObjectCaptureModel: ObservableObject {
    enum Phase {
        case idle
        case capturing
        case reconstructing(Double)
        case exporting
        case done([URL], String)
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var session: ObjectCaptureSession?
    @Published var captureState: ObjectCaptureSession.CaptureState = .initializing

    private var scanDir: URL!
    private var imagesDir: URL { scanDir.appendingPathComponent("Images", isDirectory: true) }
    private var checkpointDir: URL { scanDir.appendingPathComponent("Checkpoints", isDirectory: true) }

    func start() {
        do {
            scanDir = try FileStore.newScanFolder(prefix: "objekt")
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: checkpointDir, withIntermediateDirectories: true)
        } catch {
            phase = .failed(error.localizedDescription); return
        }

        let s = ObjectCaptureSession()
        var cfg = ObjectCaptureSession.Configuration()
        cfg.checkpointDirectory = checkpointDir
        s.start(imagesDirectory: imagesDir, configuration: cfg)
        session = s
        phase = .capturing

        Task {
            for await state in s.stateUpdates {
                captureState = state
                switch state {
                case .completed:
                    session = nil          // uvolnit paměť před rekonstrukcí
                    await reconstruct()
                    return
                case .failed(let err):
                    session = nil
                    phase = .failed(err.localizedDescription)
                    return
                default: break
                }
            }
        }
    }

    private func reconstruct() async {
        phase = .reconstructing(0)
        let usdz = scanDir.appendingPathComponent("model.usdz")
        do {
            var cfg = PhotogrammetrySession.Configuration()
            cfg.checkpointDirectory = checkpointDir
            let ps = try PhotogrammetrySession(input: imagesDir, configuration: cfg)
            // Na iOS je k dispozici jen úroveň detailu .reduced (<50k trojúhelníků).
            try ps.process(requests: [.modelFile(url: usdz)])

            loop: for try await output in ps.outputs {
                switch output {
                case .requestProgress(_, let fraction):
                    phase = .reconstructing(fraction)
                case .requestError(_, let err):
                    throw err
                case .processingComplete:
                    break loop
                default: break
                }
            }

            phase = .exporting
            let folder = scanDir!
            let (files, tris) = try await Task.detached(priority: .userInitiated) {
                let mesh = try USDZGeometryLoader.load(url: usdz).scaled(1000) // m → mm
                let files = try MeshWriter.writeAll(mesh, baseName: "model_mm", in: folder)
                return (files, mesh.triangleCount)
            }.value

            let info = "\(tris) trojúhelníků. USDZ obsahuje barevnou texturu, STL/OBJ/PLY jen geometrii v mm. Složka Images obsahuje fotky – na Macu z nich lze spočítat model v úrovni Full/Raw."
            phase = .done([usdz] + files, info)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

struct ObjectCaptureFlowView: View {
    @StateObject private var model = ObjectCaptureModel()

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                VStack(alignment: .leading, spacing: 16) {
                    Text("Tipy pro dobrý sken").font(.title2.bold())
                    Label("Rovnoměrné, rozptýlené světlo bez ostrých stínů", systemImage: "sun.max")
                    Label("Matný, neprůhledný objekt s texturou", systemImage: "circle.lefthalf.filled")
                    Label("Obcházej pomalu dokola ve 3 výškách", systemImage: "arrow.triangle.2.circlepath")
                    Label("Pro spodek použij „Otočit objekt“", systemImage: "arrow.uturn.up")
                    Spacer()
                    Button("Začít skenovat") { model.start() }
                        .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                }
                .padding()

            case .capturing:
                if let s = model.session {
                    ZStack(alignment: .bottom) {
                        ObjectCaptureView(session: s).ignoresSafeArea()
                        controls(s).padding(.bottom, 30)
                    }
                }

            case .reconstructing(let p):
                VStack(spacing: 16) {
                    ProgressView(value: p)
                    Text("Počítám 3D model… \(Int(p * 100)) %")
                    Text("Nech aplikaci na popředí, trvá to několik minut.").font(.caption).foregroundStyle(.secondary)
                }
                .padding()

            case .exporting:
                ProgressView("Exportuji STL / OBJ / PLY…")

            case .done(let files, let info):
                ExportResultView(files: files, info: info)

            case .failed(let msg):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(msg).multilineTextAlignment(.center)
                    Button("Zkusit znovu") { model.phase = .idle }
                }
                .padding()
            }
        }
        .navigationTitle("Objekt")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func controls(_ s: ObjectCaptureSession) -> some View {
        switch model.captureState {
        case .ready:
            Button("Pokračovat – zaměř objekt") { _ = s.startDetecting() }
                .buttonStyle(.borderedProminent)
        case .detecting:
            Button("Začít snímat") { s.startCapturing() }
                .buttonStyle(.borderedProminent)
        case .capturing:
            HStack {
                Button("Další průchod") { s.beginNewScanPass() }
                Button("Otočit objekt") { s.beginNewScanPassAfterFlip() }
                Button("Dokončit") { s.finish() }.buttonStyle(.borderedProminent)
            }
            .buttonStyle(.bordered)
        case .finishing:
            ProgressView("Ukládám snímky…")
        default:
            ProgressView()
        }
    }
}
