import RealityKit
import RealityKitContent

@MainActor
class AhaObjectPair {
    let id: String
    let rootEntity = Entity()
    
    private var originalEntity: Entity?
    private var alteredEntity: Entity?
    
    init(id: String) {
        self.id = id
    }
    
    // 2つのUSDZファイルを非同期で同時に読み込む関数
    func loadModels(originalName: String, alteredName: String) async {
        // async let を使って2つのファイルを並列で高速に読み込む
        async let origTask = Entity(named: originalName)
        async let altTask = Entity(named: alteredName)
        
        if let orig = try? await origTask {
            orig.name = "\(id)_original"
            orig.generateCollisionShapes(recursive: true)
            orig.components.set(InputTargetComponent())
            orig.components.set(OpacityComponent(opacity: 1.0))
            self.originalEntity = orig
            rootEntity.addChild(orig)
            alignVisualCenterWithRoot(of: orig)
        }
        
        if let alt = try? await altTask {
            alt.name = "\(id)_altered"
            alt.generateCollisionShapes(recursive: true)
            alt.components.set(InputTargetComponent())
            alt.components.set(OpacityComponent(opacity: 0.0))
            self.alteredEntity = alt
            rootEntity.addChild(alt)
            alignVisualCenterWithRoot(of: alt)
        }
    }
    
    // このペアの透明度を更新する関数
    func updateProgress(_ progress: Float) {
        originalEntity?.components[OpacityComponent.self]?.opacity = 1.0 - progress
        alteredEntity?.components[OpacityComponent.self]?.opacity = progress
    }

    /// USDZごとに異なる内部ピボットを補正し、モデルの見た目の中心を rootEntity の
    /// 原点へそろえる。rootEntity を研究室座標 (0, 0, 0) に置けば、表示中心も同位置になる。
    private func alignVisualCenterWithRoot(of entity: Entity) {
        let visualCenter = entity.visualBounds(relativeTo: rootEntity).center
        entity.position -= visualCenter
    }
}
