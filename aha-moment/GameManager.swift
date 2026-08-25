import SwiftUI
import Observation

// 読み込むモデルの情報をまとめた構造体
struct AhaModelDef {
    let id: String
    let original: String
    let altered: String
}

@Observable
class GameManager {
    private static let placementStoragePrefix = "localPlacementV2_"
    // 今後モデルが増えたら、ここの配列に追加するだけでOK
    let modelDefinitions: [AhaModelDef] = [
        AhaModelDef(id: "obj1", original: "model3.usdz", altered: "model3_sized_red.usdz"),
        AhaModelDef(id: "obj2", original: "model_tape.usdz", altered: "model_tape.usdz"),
        AhaModelDef(id: "obj3", original: "model_fab.usdz", altered: "model_fab.usdz"),
        AhaModelDef(id: "obj4", original: "model_bottole.usdz", altered: "model_bottole.usdz"),
    ]
    
    var targetId: String = "" // 今回ランダムに変化する正解のID
    var isPositionLocked = false
    var hasFoundObject = false
    var transitionProgress: Float = 0.0

    // Immersive Space は hide/show のたびに View を作り直すため、同じアプリ実行中の
    // 配置は UserDefaults のブリッジに依存せず、ここでも保持する。
    private var savedPositions: [String: SIMD3<Float>] = [:]
    private var savedRotations: [String: simd_quatf] = [:]
    private var savedScales: [String: SIMD3<Float>] = [:]
    
    init() {
        pickRandomTarget()
    }
    
    // 正解をランダムに選ぶ
    func pickRandomTarget() {
        if let randomModel = modelDefinitions.randomElement() {
            targetId = randomModel.id
            print("今回の正解オブジェクト: \(targetId)")
        }
    }
    
    // アハ体験のゆっくりとした変化をスタート
    func startTransition() {
        Task {
            let duration: TimeInterval = 20.0
            let fps = 30
            let steps = Int(duration * Double(fps))
            let stepValue = 1.0 / Float(steps)
            let interval = duration / Double(steps)
            
            try? await Task.sleep(nanoseconds: 500_000_000)
            
            for _ in 0..<steps {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await MainActor.run {
                    self.transitionProgress += stepValue
                }
            }
        }
    }
    /*
    // 🌍 アンカーID(位置と角度)の保存・読み込み
    func saveAnchorID(_ uuid: UUID, for id: String) {
        UserDefaults.standard.set(uuid.uuidString, forKey: "anchor_\(id)")
    }
    
    func getAnchorID(for id: String) -> UUID? {
        if let uuidString = UserDefaults.standard.string(forKey: "anchor_\(id)") {
            return UUID(uuidString: uuidString)
        }
        return nil
    }
    
    */

    func savePosition(_ pos: SIMD3<Float>, for id: String) {
        savedPositions[id] = pos
        UserDefaults.standard.set([Double(pos.x), Double(pos.y), Double(pos.z)], forKey: storageKey("pos", id: id))
    }

    func getPosition(for id: String) -> SIMD3<Float>? {
        if let position = savedPositions[id] { return position }
        guard let values = storedFloatValues(forKey: storageKey("pos", id: id), count: 3) else { return nil }
        let position = SIMD3<Float>(values[0], values[1], values[2])
        savedPositions[id] = position
        return position
    }

    func saveRotation(_ rot: simd_quatf, for id: String) {
        savedRotations[id] = rot
        UserDefaults.standard.set([Double(rot.vector.x), Double(rot.vector.y), Double(rot.vector.z), Double(rot.vector.w)], forKey: storageKey("rot", id: id))
    }

    func getRotation(for id: String) -> simd_quatf? {
        if let rotation = savedRotations[id] { return rotation }
        guard let values = storedFloatValues(forKey: storageKey("rot", id: id), count: 4) else { return nil }
        let rotation = simd_quatf(ix: values[0], iy: values[1], iz: values[2], r: values[3])
        savedRotations[id] = rotation
        return rotation
    }
 
    // 📏 スケール(大きさ)の保存・読み込み
    func saveScale(_ scale: SIMD3<Float>, for id: String) {
        savedScales[id] = scale
        UserDefaults.standard.set([Double(scale.x), Double(scale.y), Double(scale.z)], forKey: storageKey("scale", id: id))
    }
    
    func getScale(for id: String) -> SIMD3<Float>? {
        if let scale = savedScales[id] { return scale }
        guard let values = storedFloatValues(forKey: storageKey("scale", id: id), count: 3) else { return nil }
        let scale = SIMD3<Float>(values[0], values[1], values[2])
        savedScales[id] = scale
        return scale
    }
    
    // GameManager.swift の一番下など（クラスの波括弧 } の直前）に以下を追加します

        // 🌟 追加: ゲームの状態をリセットして最初から遊べるようにする
        func resetGameState() {
            isPositionLocked = false
            hasFoundObject = false
            transitionProgress = 0.0
            pickRandomTarget() // 新しい正解をランダムに選び直す
        }

    private func storedFloatValues(forKey key: String, count: Int) -> [Float]? {
        guard let values = UserDefaults.standard.array(forKey: key), values.count == count else { return nil }
        let floatValues = values.compactMap { ($0 as? NSNumber)?.floatValue }
        return floatValues.count == count ? floatValues : nil
    }

    private func storageKey(_ valueType: String, id: String) -> String {
        "\(Self.placementStoragePrefix)\(valueType)_\(id)"
    }
}
