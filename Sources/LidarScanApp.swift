import SwiftUI
import RealityKit
import ARKit

@main
struct LidarScanApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ObjectCaptureFlowView()
                    } label: {
                        ModeRow(title: "Objekt – vysoká kvalita",
                                subtitle: "LiDAR + 48MP fotogrammetrie (Object Capture). Pro 3D tisk.",
                                icon: "cube.transparent")
                    }
                    .disabled(!ObjectCaptureSession.isSupported)

                    NavigationLink {
                        LidarScanView()
                    } label: {
                        ModeRow(title: "Rychlý LiDAR mesh",
                                subtitle: "Čistě hloubková síť ARKitu. Větší předměty, nábytek, místnosti.",
                                icon: "dot.radiowaves.left.and.right")
                    }
                    .disabled(!ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh))
                } footer: {
                    Text("Výsledky se ukládají do aplikace Soubory → Na mém iPhonu → LiDAR Scan. Exporty STL/OBJ/PLY jsou v milimetrech.")
                }
            }
            .navigationTitle("LiDAR Scan")
        }
    }
}

private struct ModeRow: View {
    let title: String, subtitle: String, icon: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title2).frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Společné: složky a obrazovka s výsledky

enum FileStore {
    static func newScanFolder(prefix: String) throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = docs.appendingPathComponent("\(prefix)_\(f.string(from: Date()))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct ExportResultView: View {
    let files: [URL]
    let info: String

    var body: some View {
        List {
            Section { Text(info).font(.callout) }
            Section("Soubory") {
                ForEach(files, id: \.self) { url in
                    ShareLink(item: url) {
                        HStack {
                            Text(url.lastPathComponent)
                            Spacer()
                            Text(sizeString(url)).foregroundStyle(.secondary)
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            Section {
                ShareLink("Sdílet vše", items: files)
            }
        }
    }

    private func sizeString(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
