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

    /// 研究室で定義した基準点。最後の点は、依頼中で二度「原点3」と記載された
    /// `(0.5, -0.085, 0)` を原点4として扱う。
    private let laboratoryReferencePoints: [SIMD3<Float>] = [
        SIMD3(0, 0, 0),
        SIMD3(0, 0.4, 0),
        SIMD3(0, 0, 0.42),
        SIMD3(0.5, -0.085, 0),
    ]

    /// 各モデルの研究室座標（単位: m）。指定座標を5倍している。
    private let laboratoryObjectPositions: [String: SIMD3<Float>] = [
        "obj1": SIMD3(-0.1, 1.69, -0.2),
        "obj2": SIMD3(-0.1, 0.5, 0.05),
        "obj3": SIMD3(-0.08, 1.7, -0.85),
        "obj4": SIMD3(-0.13, 1.69, 2),
    ]

    // 🌟 追加: モデルごとの拡大率（未指定のIDはdefaultScaleを使う）
    private let laboratoryObjectScales: [String: Float] = [
        "obj1": 1.0 / 2.5,
        "obj2": 1.0 / 3.0,
        "obj3": 1.0 / 2.8,
        "obj4": 1.0 / 2.8,
    ]
    private let defaultScale: Float = 1.0 / 3.0

    // 🌟 追加: モデルごとのY軸回転角（度数）。未指定のIDはdefaultYRotationDegreesを使う
    private let laboratoryObjectYRotationDegrees: [String: Float] = [
        "obj1": 0,
        "obj2": 180,
        "obj3": 270,   // 例: obj3だけ90度に変更したい場合
        "obj4": -90,    // 例: obj4は回転なしにしたい場合
    ]
    private let defaultYRotationDegrees: Float = 180        // 今後モデルが増えたら、ここの配列に追加するだけでOK
    let modelDefinitions: [AhaModelDef] = [
        AhaModelDef(id: "obj1", original: "model3.usdz", altered: "model3_sized_red.usdz"),
        AhaModelDef(id: "obj2", original: "model_tape.usdz", altered: "model_tape_alt.usdz"),
        AhaModelDef(id: "obj3", original: "model_fab.usdz", altered: "model_fab.usdz"),
        AhaModelDef(id: "obj4", original: "model_bottole.usdz", altered: "model_bottole.usdz"),
    ]
    
    var targetId: String = "" // 今回ランダムに変化する正解のID
    var isPositionLocked = false
    var hasFoundObject = false
    var transitionProgress: Float = 0.0

    private(set) var calibrationPoints: [SIMD3<Float>] = []
    private(set) var isCalibrated = false
    private var laboratoryToARTransform = matrix_identity_float4x4
    private var stableFingerPosition: SIMD3<Float>?
    private var stableFingerSince: Date?
    private var stableFingerPositionSum = SIMD3<Float>(repeating: 0)
    private var stableFingerSampleCount = 0
    private var lastCapturedFingerPosition: SIMD3<Float>?
    private var isWaitingForFingerToMove = false

    private let calibrationHoldDuration: TimeInterval = 0.8
    private let calibrationStabilityRadius: Float = 0.012
    private let minimumMoveBeforeNextCapture: Float = 0.08

    var nextCalibrationPointNumber: Int {
        min(calibrationPoints.count + 1, laboratoryReferencePoints.count)
    }

    var calibrationPointCount: Int { calibrationPoints.count }

    var calibrationInstruction: String {
        isWaitingForFingerToMove
            ? "次の基準点まで指を8cm以上移動してください"
            : "人差し指の先を基準点に触れ、0.8秒静止してください"
    }

    // Immersive Space は hide/show のたびに View を作り直すため、同じアプリ実行中の
    // 配置は UserDefaults のブリッジに依存せず、ここでも保持する。
    private var savedPositions: [String: SIMD3<Float>] = [:]
    private var savedRotations: [String: simd_quatf] = [:]
    private var savedScales: [String: SIMD3<Float>] = [:]
    
    init() {
        pickRandomTarget()
    }

    /// Immersive Space を開くたびに呼び、前回のAR座標系を破棄する。
    func restartCalibration() {
        calibrationPoints.removeAll()
        isCalibrated = false
        laboratoryToARTransform = matrix_identity_float4x4
        isPositionLocked = false
        hasFoundObject = false
        transitionProgress = 0
        resetCalibrationFingerTracking()
    }

    /// 人差し指が物理的な基準点で静止したことを検出し、先端座標を自動取得する。
    func updateCalibrationFingerPosition(_ position: SIMD3<Float>, at date: Date = .now) {
        guard !isCalibrated else { return }

        if isWaitingForFingerToMove {
            if let lastCapturedFingerPosition,
               distance(position, lastCapturedFingerPosition) >= minimumMoveBeforeNextCapture {
                isWaitingForFingerToMove = false
                beginCalibrationFingerTracking(at: position, date: date)
            }
            return
        }

        guard let stableFingerPosition,
              let stableFingerSince else {
            beginCalibrationFingerTracking(at: position, date: date)
            return
        }

        guard distance(position, stableFingerPosition) <= calibrationStabilityRadius else {
            beginCalibrationFingerTracking(at: position, date: date)
            return
        }

        stableFingerPositionSum += position
        stableFingerSampleCount += 1
        guard date.timeIntervalSince(stableFingerSince) >= calibrationHoldDuration else { return }
        let averagedPosition = stableFingerPositionSum / Float(stableFingerSampleCount)
        captureCalibrationPoint(averagedPosition)
        lastCapturedFingerPosition = averagedPosition
        isWaitingForFingerToMove = true
        resetCalibrationFingerTracking()
    }

    func resetCalibrationFingerTracking() {
        stableFingerPosition = nil
        stableFingerSince = nil
        stableFingerPositionSum = .zero
        stableFingerSampleCount = 0
    }

    /// 指先で指定したAR座標を、原点1〜4の順に記録する。
    private func captureCalibrationPoint(_ point: SIMD3<Float>) {
        guard !isCalibrated, calibrationPoints.count < laboratoryReferencePoints.count else { return }

        calibrationPoints.append(point)
        print("📍 基準点\(calibrationPoints.count) を取得: \(point)")

        guard calibrationPoints.count == laboratoryReferencePoints.count else { return }
        guard let transform = makeAffineTransform(
            from: laboratoryReferencePoints,
            to: calibrationPoints
        ) else {
            print("⚠️ キャリブレーションに失敗しました。4点を取り直してください。")
            calibrationPoints.removeAll()
            resetCalibrationFingerTracking()
            return
        }

        laboratoryToARTransform = transform
        isCalibrated = true
        print("✅ 4点キャリブレーション完了")
    }

    private func beginCalibrationFingerTracking(at position: SIMD3<Float>, date: Date) {
        stableFingerPosition = position
        stableFingerSince = date
        stableFingerPositionSum = position
        stableFingerSampleCount = 1
    }

    func calibratedPosition(for modelID: String) -> SIMD3<Float>? {
        guard isCalibrated, let laboratoryPosition = laboratoryObjectPositions[modelID] else { return nil }
        let homogeneousPosition = laboratoryToARTransform * SIMD4(laboratoryPosition, 1)
        return SIMD3(homogeneousPosition.x, homogeneousPosition.y, homogeneousPosition.z)
    }

    func scale(for modelID: String) -> SIMD3<Float> {
        let value = laboratoryObjectScales[modelID] ?? defaultScale
        return SIMD3(repeating: value)
    }

    /// 「横」は床に対して水平なY軸回転として扱う。
    /// モデルごとのY軸回転（「横」は床に対して水平な回転として扱う）。
    func orientation(for modelID: String) -> simd_quatf {
        let degrees = laboratoryObjectYRotationDegrees[modelID] ?? defaultYRotationDegrees
        let radians = degrees * .pi / 180
        return simd_quatf(angle: radians, axis: SIMD3(0, 1, 0))
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

    /// `to = transform * from` を満たす4点アフィン変換を作る。
    private func makeAffineTransform(
        from source: [SIMD3<Float>],
        to destination: [SIMD3<Float>]
    ) -> simd_float4x4? {
        guard source.count == 4, destination.count == 4 else { return nil }

        let sourceMatrix = matrixFromRows(source.map { SIMD4($0.x, $0.y, $0.z, 1) })
        let determinant = simd_determinant(sourceMatrix)
        guard abs(determinant) > 0.000_001 else { return nil }

        let destinationMatrix = matrixFromRows(destination.map { SIMD4($0.x, $0.y, $0.z, 1) })
        let rowTransform = simd_inverse(sourceMatrix) * destinationMatrix

        // 行ベクトル形式で解いた変換を、RealityKit の列ベクトル形式に転置する。
        return simd_float4x4(
            columns: (
                SIMD4(rowTransform.columns.0.x, rowTransform.columns.1.x, rowTransform.columns.2.x, rowTransform.columns.3.x),
                SIMD4(rowTransform.columns.0.y, rowTransform.columns.1.y, rowTransform.columns.2.y, rowTransform.columns.3.y),
                SIMD4(rowTransform.columns.0.z, rowTransform.columns.1.z, rowTransform.columns.2.z, rowTransform.columns.3.z),
                SIMD4(rowTransform.columns.0.w, rowTransform.columns.1.w, rowTransform.columns.2.w, rowTransform.columns.3.w)
            )
        )
    }

    private func matrixFromRows(_ rows: [SIMD4<Float>]) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(rows[0].x, rows[1].x, rows[2].x, rows[3].x),
            SIMD4(rows[0].y, rows[1].y, rows[2].y, rows[3].y),
            SIMD4(rows[0].z, rows[1].z, rows[2].z, rows[3].z),
            SIMD4(rows[0].w, rows[1].w, rows[2].w, rows[3].w)
        ))
    }
}
