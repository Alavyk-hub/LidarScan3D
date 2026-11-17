import Foundation
import ModelIO
import simd

/// Jednoduchá trojúhelníková síť (souřadnice v metrech, dokud se nezavolá `scaled`).
struct TriMesh: Sendable {
    var vertices: [SIMD3<Float>] = []
    var indices: [UInt32] = []

    var triangleCount: Int { indices.count / 3 }

    mutating func append(_ other: TriMesh) {
        let offset = UInt32(vertices.count)
        vertices.append(contentsOf: other.vertices)
        indices.append(contentsOf: other.indices.map { $0 + offset })
    }

    /// 1000 = převod z metrů na milimetry (slicery STL/OBJ chápou jako mm).
    func scaled(_ s: Float) -> TriMesh {
        TriMesh(vertices: vertices.map { $0 * s }, indices: indices)
    }

    /// Ponechá jen trojúhelníky, jejichž všechny vrcholy leží v kouli (střed, poloměr)
    /// a zároveň nad rovinou `minY` (odřízne podlahu / stůl).
    func cropped(center: SIMD3<Float>, radius: Float, minY: Float? = nil) -> TriMesh {
        let r2 = radius * radius
        let inside = vertices.map { v -> Bool in
            simd_length_squared(v - center) <= r2 && (minY == nil || v.y >= minY!)
        }
        var remap = [Int32](repeating: -1, count: vertices.count)
        var out = TriMesh()
        for t in stride(from: 0, to: indices.count - 2, by: 3) {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            guard inside[a], inside[b], inside[c] else { continue }
            for i in [a, b, c] {
                if remap[i] < 0 {
                    remap[i] = Int32(out.vertices.count)
                    out.vertices.append(vertices[i])
                }
                out.indices.append(UInt32(remap[i]))
            }
        }
        return out
    }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case stl, obj, ply
    case asc   // mračno bodů „x y z“ – pro FreeCAD (Points / Reverse Engineering)
    var id: String { rawValue }
}

enum MeshWriter {
    static func write(_ mesh: TriMesh, to url: URL, format: ExportFormat) throws {
        let data: Data
        switch format {
        case .stl: data = binarySTL(mesh)
        case .obj: data = obj(mesh)
        case .ply: data = binaryPLY(mesh)
        case .asc: data = asc(mesh)
        }
        try data.write(to: url, options: .atomic)
    }

    /// Exportuje všechny formáty do složky, vrátí URL souborů.
    static func writeAll(_ mesh: TriMesh, baseName: String, in folder: URL) throws -> [URL] {
        try ExportFormat.allCases.map { fmt in
            let url = folder.appendingPathComponent("\(baseName).\(fmt.rawValue)")
            try write(mesh, to: url, format: fmt)
            return url
        }
    }

    // MARK: Binární STL
    private static func binarySTL(_ m: TriMesh) -> Data {
        var d = Data(capacity: 84 + m.triangleCount * 50)
        var header = Data("LidarScan3D binary STL (mm)".utf8)
        header.append(Data(count: 80 - header.count))
        d.append(header)
        d.appendLE(UInt32(m.triangleCount))
        for t in stride(from: 0, to: m.indices.count - 2, by: 3) {
            let a = m.vertices[Int(m.indices[t])]
            let b = m.vertices[Int(m.indices[t + 1])]
            let c = m.vertices[Int(m.indices[t + 2])]
            var n = simd_cross(b - a, c - a)
            let len = simd_length(n)
            n = len > 0 ? n / len : .zero
            for v in [n, a, b, c] { d.appendLE(v.x); d.appendLE(v.y); d.appendLE(v.z) }
            d.appendLE(UInt16(0))
        }
        return d
    }

    // MARK: OBJ (text)
    private static func obj(_ m: TriMesh) -> Data {
        var s = "# LidarScan3D OBJ, jednotky: mm\n"
        s.reserveCapacity(m.vertices.count * 32 + m.indices.count * 8)
        for v in m.vertices { s += "v \(v.x) \(v.y) \(v.z)\n" }
        for t in stride(from: 0, to: m.indices.count - 2, by: 3) {
            s += "f \(m.indices[t] + 1) \(m.indices[t + 1] + 1) \(m.indices[t + 2] + 1)\n"
        }
        return Data(s.utf8)
    }

    // MARK: ASC mračno bodů (FreeCAD Points workbench)
    private static func asc(_ m: TriMesh) -> Data {
        var s = ""
        s.reserveCapacity(m.vertices.count * 30)
        for v in m.vertices { s += "\(v.x) \(v.y) \(v.z)\n" }
        return Data(s.utf8)
    }

    // MARK: Binární PLY
    private static func binaryPLY(_ m: TriMesh) -> Data {
        let header = """
        ply
        format binary_little_endian 1.0
        comment LidarScan3D, units mm
        element vertex \(m.vertices.count)
        property float x
        property float y
        property float z
        element face \(m.triangleCount)
        property list uchar int vertex_indices
        end_header

        """
        var d = Data(header.utf8)
        for v in m.vertices { d.appendLE(v.x); d.appendLE(v.y); d.appendLE(v.z) }
        for t in stride(from: 0, to: m.indices.count - 2, by: 3) {
            d.append(UInt8(3))
            d.appendLE(Int32(m.indices[t])); d.appendLE(Int32(m.indices[t + 1])); d.appendLE(Int32(m.indices[t + 2]))
        }
        return d
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ v: Float) { appendLE(v.bitPattern) }
}

/// Načte geometrii z USDZ (výstup Object Capture) a „zapeče“ transformace do světových souřadnic.
enum USDZGeometryLoader {
    static func load(url: URL) throws -> TriMesh {
        let asset = MDLAsset(url: url)
        var result = TriMesh()
        for case let mesh as MDLMesh in asset.childObjects(of: MDLMesh.self) {
            let world = MDLTransform.globalTransform(with: mesh, atTime: 0)
            guard let pos = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3)
            else { continue }

            var part = TriMesh()
            part.vertices.reserveCapacity(mesh.vertexCount)
            for i in 0..<mesh.vertexCount {
                let p = pos.dataStart.advanced(by: i * pos.stride).assumingMemoryBound(to: Float.self)
                let w = world * SIMD4<Float>(p[0], p[1], p[2], 1)
                part.vertices.append(SIMD3(w.x, w.y, w.z))
            }
            for case let sub as MDLSubmesh in ((mesh.submeshes as? [MDLSubmesh]) ?? []) where sub.geometryType == .triangles {
                let buf = sub.indexBuffer(asIndexType: .uInt32)
                let ptr = buf.map().bytes.assumingMemoryBound(to: UInt32.self)
                part.indices.append(contentsOf: UnsafeBufferPointer(start: ptr, count: sub.indexCount))
            }
            result.append(part)
        }
        guard result.triangleCount > 0 else {
            throw NSError(domain: "LidarScan3D", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "USDZ neobsahuje žádnou trojúhelníkovou síť."])
        }
        return result
    }
}
