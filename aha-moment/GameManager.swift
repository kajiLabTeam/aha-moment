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
    var isMenuVisible = true
    private(set) var menuPresentationRequest = 0
    private var transitionTask: Task<Void, Never>?

    private(set) var calibrationPoints: [SIMD3<Float>] = []
    private(set) var isCalibrated = false
    var isAdjustmentMode = false
    var isOcclusionBoxPlacementMode = false
    private(set) var requestedOcclusionBoxCount = 0
    private var laboratoryToARTransform = matrix_identity_float4x4
    private var positionAdjustments: [String: SIMD3<Float>] = [:]
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
        isAdjustmentMode = false
        isOcclusionBoxPlacementMode = false
        requestedOcclusionBoxCount = 0
        laboratoryToARTransform = matrix_identity_float4x4
        positionAdjustments.removeAll()
        isPositionLocked = false
        hasFoundObject = false
        transitionProgress = 0
        isMenuVisible = true
        menuPresentationRequest += 1
        transitionTask?.cancel()
        transitionTask = nil
        lastCapturedFingerPosition = nil
        isWaitingForFingerToMove = false
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
        guard let transform = makeRigidTransform(
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
        // キャリブレーション完了後の設定メニューは、手のひらジェスチャーで呼び出す。
        isMenuVisible = false
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
        let basePosition = SIMD3(homogeneousPosition.x, homogeneousPosition.y, homogeneousPosition.z)
        return basePosition + (positionAdjustments[modelID] ?? .zero)
    }

    /// 微調整モードでドラッグした最終ワールド座標を、基準配置からの差分として保存する。
    func savePositionAdjustment(_ worldPosition: SIMD3<Float>, for modelID: String) {
        guard isCalibrated, let laboratoryPosition = laboratoryObjectPositions[modelID] else { return }
        let homogeneousPosition = laboratoryToARTransform * SIMD4(laboratoryPosition, 1)
        let basePosition = SIMD3(homogeneousPosition.x, homogeneousPosition.y, homogeneousPosition.z)
        positionAdjustments[modelID] = worldPosition - basePosition
        print("🔧 \(modelID) 微調整: \(positionAdjustments[modelID]!)")
    }

    func clearPositionAdjustments() {
        positionAdjustments.removeAll()
    }

    func requestOcclusionBox() {
        isAdjustmentMode = false
        isOcclusionBoxPlacementMode = true
        requestedOcclusionBoxCount += 1
    }

    func finishOcclusionBoxPlacement() {
        isOcclusionBoxPlacementMode = false
    }

    func clearOcclusionBoxes() {
        requestedOcclusionBoxCount = 0
        isOcclusionBoxPlacementMode = false
    }

    /// 手のひらを自分へ向けるジェスチャーで、メニューを現在の視界前方に出す。
    func requestMenuPresentation() {
        isMenuVisible = true
        menuPresentationRequest += 1
    }

    /// 4点キャリブレーションで得た棚座標系の向き。生成するボックスを棚と平行にする。
    var calibrationOrientation: simd_quatf {
        // simd_quatf には SDK によって `.identity` が定義されないため、
        // 明示的なゼロ回転を使う。
        guard isCalibrated else {
            return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        }
        let matrix = laboratoryToARTransform
        let rotation = simd_float3x3(columns: (
            SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
            SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
            SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
        ))
        return simd_quatf(rotation)
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
        transitionTask?.cancel()
        transitionProgress = 0
        isMenuVisible = false
        transitionTask = Task { [weak self] in
            guard let self else { return }
            let duration: TimeInterval = 20.0
            let fps = 30
            let steps = Int(duration * Double(fps))
            let stepValue = 1.0 / Float(steps)
            let interval = duration / Double(steps)
            
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            
            for _ in 0..<steps {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.transitionProgress = min(self.transitionProgress + stepValue, 1)
                }
            }
        }
    }

    /// 次の問題へ移る前に、進行中の変化を止めて全モデルを変化前へ戻す。
    func playAgain() {
        transitionTask?.cancel()
        transitionTask = nil
        isPositionLocked = false
        hasFoundObject = false
        transitionProgress = 0
        pickRandomTarget()
        requestMenuPresentation()
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
    
    private func storedFloatValues(forKey key: String, count: Int) -> [Float]? {
        guard let values = UserDefaults.standard.array(forKey: key), values.count == count else { return nil }
        let floatValues = values.compactMap { ($0 as? NSNumber)?.floatValue }
        return floatValues.count == count ? floatValues : nil
    }

    private func storageKey(_ valueType: String, id: String) -> String {
        "\(Self.placementStoragePrefix)\(valueType)_\(id)"
    }

    /// 4点から回転と並進だけの変換を作る。手指で取得した基準点に少し誤差があっても、
    /// オブジェクトに不自然な拡大縮小やせん断が掛からず、実空間に対して安定する。
    private func makeRigidTransform(
        from source: [SIMD3<Float>],
        to destination: [SIMD3<Float>]
    ) -> simd_float4x4? {
        guard source.count == 4, destination.count == 4 else { return nil }

        guard let sourceBasis = orthonormalBasis(from: source),
              let destinationBasis = orthonormalBasis(from: destination) else { return nil }

        let rotation = destinationBasis * sourceBasis.transpose
        let translation = destination[0] - rotation * source[0]

        return simd_float4x4(columns: (
            SIMD4(rotation.columns.0, 0),
            SIMD4(rotation.columns.1, 0),
            SIMD4(rotation.columns.2, 0),
            SIMD4(translation, 1)
        ))
    }

    /// 基準点1を原点、2をY方向、3をZ方向、4をX方向の符号確認に利用する。
    private func orthonormalBasis(from points: [SIMD3<Float>]) -> simd_float3x3? {
        let origin = points[0]
        let yRaw = points[1] - origin
        let zRaw = points[2] - origin
        guard length(yRaw) > 0.001, length(zRaw) > 0.001 else { return nil }

        let yAxis = normalize(yRaw)
        let zOrthogonal = zRaw - yAxis * dot(zRaw, yAxis)
        guard length(zOrthogonal) > 0.001 else { return nil }
        var zAxis = normalize(zOrthogonal)
        var xAxis = normalize(cross(yAxis, zAxis))

        // 基準点4が正のX側に来るように符号をそろえる。
        if dot(points[3] - origin, xAxis) < 0 {
            xAxis = -xAxis
            zAxis = -zAxis
        }

        return simd_float3x3(columns: (xAxis, yAxis, zAxis))
    }
}
