import SwiftUI
import RealityKit
import ARKit

/// Režim 2: čistý LiDAR mesh z ARKitu (ARMeshAnchor). Rychlé, ale hrubší (~1–2 cm).
final class LidarScanController: NSObject, ObservableObject, ARSessionDelegate {
    let arView = ARView(frame: .zero)
    @Published var anchorCount = 0
    @Published var center: SIMD3<Float>?
    private var marker: AnchorEntity?

    func start() {
        let cfg = ARWorldTrackingConfiguration()
        cfg.sceneReconstruction = .mesh
        cfg.environmentTexturing = .none
        arView.session.delegate = self
        arView.debugOptions.insert(.showSceneUnderstanding)   // zobrazí drátový model sítě
        arView.session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
        DispatchQueue.main.async { self.anchorCount = 0; self.center = nil }
    }

    func pause() { arView.session.pause() }

    /// Klepnutím na objekt nastaví střed oblasti, která se exportuje.
    func setCenter(at point: CGPoint) {
        guard let hit = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first else { return }
        let c = hit.worldTransform.columns.3
        center = SIMD3(c.x, c.y, c.z)

        marker?.removeFromParent()
        let m = AnchorEntity(world: hit.worldTransform)
        m.addChild(ModelEntity(mesh: .generateSphere(radius: 0.01),
                               materials: [SimpleMaterial(color: .systemRed, isMetallic: false)]))
        arView.scene.addAnchor(m)
        marker = m
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let n = session.currentFrame?.anchors.filter { $0 is ARMeshAnchor }.count ?? 0
        DispatchQueue.main.async { self.anchorCount = n }
    }

    /// Spojí všechny ARMeshAnchory do jedné sítě ve světových souřadnicích (metry).
    func collectMesh() -> TriMesh {
        let anchors = arView.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        var result = TriMesh()
        for anchor in anchors {
            let g = anchor.geometry
            var part = TriMesh()
            let vs = g.vertices
            let vBase = vs.buffer.contents().advanced(by: vs.offset)
            part.vertices.reserveCapacity(vs.count)
            for i in 0..<vs.count {
                let p = vBase.advanced(by: i * vs.stride).assumingMemoryBound(to: Float.self)
                let w = anchor.transform * SIMD4<Float>(p[0], p[1], p[2], 1)
                part.vertices.append(SIMD3(w.x, w.y, w.z))
            }
            let f = g.faces
            let fBase = f.buffer.contents()
            let total = f.count * f.indexCountPerPrimitive
            part.indices.reserveCapacity(total)
            for i in 0..<total {
                let ptr = fBase.advanced(by: i * f.bytesPerIndex)
                let idx: UInt32 = f.bytesPerIndex == 2
                    ? UInt32(ptr.assumingMemoryBound(to: UInt16.self).pointee)
                    : ptr.assumingMemoryBound(to: UInt32.self).pointee
                part.indices.append(idx)
            }
            result.append(part)
        }
        return result
    }
}

private struct ARViewContainer: UIViewRepresentable {
    let controller: LidarScanController

    func makeUIView(context: Context) -> ARView {
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        controller.arView.addGestureRecognizer(tap)
        return controller.arView
    }
    func updateUIView(_ uiView: ARView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(controller) }

    final class Coordinator: NSObject {
        let controller: LidarScanController
        init(_ c: LidarScanController) { controller = c }
        @objc func tapped(_ g: UITapGestureRecognizer) {
            controller.setCenter(at: g.location(in: controller.arView))
        }
    }
}

struct LidarScanView: View {
    @StateObject private var controller = LidarScanController()
    @State private var radiusCm: Double = 30
    @State private var cutFloor = true
    @State private var result: (files: [URL], info: String)?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Group {
            if let result {
                ExportResultView(files: result.files, info: result.info)
            } else {
                ZStack(alignment: .bottom) {
                    ARViewContainer(controller: controller).ignoresSafeArea()
                    panel
                }
            }
        }
        .navigationTitle("LiDAR mesh")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { controller.start() }
        .onDisappear { controller.pause() }
        .alert("Chyba", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var panel: some View {
        VStack(spacing: 10) {
            Text(controller.center == nil
                 ? "Obcházej objekt, pak na něj klepni (nastaví střed výřezu)."
                 : "Střed nastaven. Oblastí sítě: \(controller.anchorCount)")
                .font(.footnote).multilineTextAlignment(.center)

            HStack {
                Text("Poloměr \(Int(radiusCm)) cm")
                Slider(value: $radiusCm, in: 5...150, step: 5)
            }
            Toggle("Odříznout podložku pod středem", isOn: $cutFloor)

            HStack {
                Button("Reset") { controller.start() }.buttonStyle(.bordered)
                Button(busy ? "Exportuji…" : "Exportovat") { export() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || controller.anchorCount == 0)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding()
    }

    private func export() {
        busy = true
        let raw = controller.collectMesh()
        controller.pause()
        let center = controller.center
        let radius = Float(radiusCm / 100)
        let floorCut = cutFloor
        Task.detached(priority: .userInitiated) {
            do {
                // podložka: ponecháme jen body 3 mm nad bodem, na který se klepnulo (klepni na stůl vedle objektu)
                let mesh = center.map { c in
                    raw.cropped(center: c, radius: radius, minY: floorCut ? c.y + 0.003 : nil)
                } ?? raw
                let mm = mesh.scaled(1000)
                let folder = try FileStore.newScanFolder(prefix: "lidar")
                let files = try MeshWriter.writeAll(mm, baseName: "lidar_mm", in: folder)
                let info = "\(mm.triangleCount) trojúhelníků, \(mm.vertices.count) vrcholů. Jednotky mm. Před tiskem síť uzavři (Blender / Meshmixer / PrusaSlicer – oprava modelu)."
                await MainActor.run { result = (files, info); busy = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; busy = false }
            }
        }
    }
}
