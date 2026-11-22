import SwiftUI
import SceneKit
import BrahmaCore
import BrahmaAppModel
import BrahmaMapKit

/// A glTF or glb artifact of at most `RendererCaps.maxInProcessModelBytes` (Plan 4a Task 9b; `FileBody.make` sends larger
/// ones to the file card and the other 3D formats to Quick Look). The file goes through `GLTFMesh.load` (the bounds-checked
/// parser: every accessor, index and buffer is verified before a byte is read, and the caps bound what is held) under
/// `RendererCaps.parse`, so only floats and indices reach SceneKit: one `SCNGeometry` with a `text1` material in an `SCNView`
/// the owner can orbit. Past the parse timeout the body says `CAN'T SHOW THIS FILE`; any other failure `CAN'T SHOW THIS MODEL`.
/// `GLTFMesh` ignores node transforms (an accepted MVP limitation), so `FileBody.gltfNote` sits in the footer.
struct ModelPreviewView: View {
    let url: URL
    @State private var load: FileLoad<GLTFMesh>?

    static let cantShowTitle = "CAN'T SHOW THIS MODEL"

    var body: some View {
        Group {
            switch load {
            case nil:
                Color.clear
            case .failed(let title, let detail)?:
                FileLoadFailure(title: title, detail: detail)
            case .ready(let mesh)?:
                VStack(spacing: 0) {
                    ModelSceneView(mesh: mesh)
                        .id(url)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel(Text(verbatim: url.lastPathComponent))
                    Hairline()
                    HStack(spacing: BrahmaTheme.spaceS) {
                        MonoChip(text: "\(mesh.positions.count / 3) VERTICES", color: BrahmaTheme.text2, fill: BrahmaTheme.bg3)
                        MonoChip(text: "\(mesh.indices.count / 3) TRIANGLES", color: BrahmaTheme.text2, fill: BrahmaTheme.bg3)
                        Text(verbatim: FileBody.gltfNote)
                            .font(BrahmaTheme.monoTiny)
                            .foregroundStyle(BrahmaTheme.text2)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, BrahmaTheme.spaceS)
                    .frame(height: BrahmaTheme.denseRowHeight)
                    .background(BrahmaTheme.bg2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrahmaTheme.bg0)
        .task(id: url) {
            load = nil
            if let result = await Self.load(url) { load = result }
        }
    }

    /// The mesh, or why not; nil when the caller was cancelled. A timeout is the shared `CAN'T SHOW THIS FILE`; the model's own
    /// refusals (over a cap, contradicting itself, a feature the viewer lacks, no triangles) are `CAN'T SHOW THIS MODEL`.
    static func load(_ url: URL) async -> FileLoad<GLTFMesh>? {
        do {
            let mesh = try await RendererCaps.parse { try GLTFMesh.load(url) }
            guard mesh.indices.count >= 3, mesh.positions.count >= 9 else {
                return .failed(title: cantShowTitle, detail: "it has no triangles")
            }
            return .ready(mesh)
        } catch is CancellationError {
            return nil
        } catch RendererError.timedOut {
            return .timedOut
        } catch GLTFError.tooLarge {
            return .failed(title: cantShowTitle, detail: "it is larger than this preview reads")
        } catch GLTFError.invalid(let why) {
            return .failed(title: cantShowTitle, detail: why)
        } catch GLTFError.unsupported(let what) {
            return .failed(title: cantShowTitle, detail: "not supported here: " + what)
        } catch {
            return .failed(title: cantShowTitle, detail: "it couldn't be read")
        }
    }
}

/// The `SCNView`: the mesh as one node at the origin, a camera backed off to fit its bounding sphere, default lighting, and
/// the owner's orbit (`allowsCameraControl`). Built once per view; the parent re-creates it per file (`.id(url)`).
private struct ModelSceneView: NSViewRepresentable {
    let mesh: GLTFMesh

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = MapPalette.color(ThemeHex.bg0)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.scene = Self.scene(for: mesh)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {}

    static func scene(for mesh: GLTFMesh) -> SCNScene {
        let scene = SCNScene()
        let vertexCount = mesh.positions.count / 3
        var sources = [SCNGeometrySource(data: mesh.positions.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .vertex,
                                         vectorCount: vertexCount, usesFloatComponents: true, componentsPerVector: 3,
                                         bytesPerComponent: 4, dataOffset: 0, dataStride: 12)]
        let lit: Bool
        if let normals = mesh.normals, normals.count == mesh.positions.count {
            sources.append(SCNGeometrySource(data: normals.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .normal,
                                             vectorCount: vertexCount, usesFloatComponents: true, componentsPerVector: 3,
                                             bytesPerComponent: 4, dataOffset: 0, dataStride: 12))
            lit = true
        } else {
            lit = false
        }
        let element = SCNGeometryElement(data: mesh.indices.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: .triangles,
                                         primitiveCount: mesh.indices.count / 3, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = MapPalette.color(ThemeHex.text1)
        // Without normals a lit model is black; a flat silhouette in `text1` is still a geometry preview.
        material.lightingModel = lit ? .blinn : .constant
        material.isDoubleSided = true
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        scene.rootNode.addChildNode(node)

        let camera = SCNCamera()
        camera.automaticallyAdjustsZRange = true
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        let (center, radius) = node.boundingSphere
        let halfFOV = Double(camera.fieldOfView) / 2 * .pi / 180
        let distance = max(Double(radius), 0.001) / tan(halfFOV) * 1.2
        cameraNode.position = SCNVector3(center.x, center.y, center.z + CGFloat(distance))
        cameraNode.look(at: center)
        scene.rootNode.addChildNode(cameraNode)
        return scene
    }
}
