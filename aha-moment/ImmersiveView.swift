import SwiftUI
import RealityKit
import RealityKitContent
import ARKit
import QuartzCore

/// RealityView の更新中に SwiftUI の State を書き換えないための、
/// オクルージョンボックス実体の保持領域。
private final class DirectOcclusionBoxStore {
    let rootEntity = Entity()
    var boxes: [Entity] = []
    var guideEntities: [Entity] = []
    var identifiers: [UInt64: UUID] = [:]
}

/// 座標共有完了後に、両端末で同じ物理位置を確認するための一時マーカー。
private final class CoordinateValidationMarkerStore {
    let rootEntity = Entity()
    var markerEntity: Entity?
}

private final class MenuEntityStore {
    var entity: Entity?
    var lastPresentationRequest = -1
}

private final class HandGestureStore {
    var wasPalmFacingPlayer = false
}

@MainActor
struct ImmersiveView: View {
    @Environment(GameManager.self) var gameManager
    @Environment(AppModel.self) private var appModel
    
    @State private var dragOffsets: [UInt64: SIMD3<Float>] = [:]
    @State private var initialScales: [UInt64: SIMD3<Float>] = [:]
    @State private var initialOrientations: [UInt64: simd_quatf] = [:]
    
    @State private var loadedPairs: [String: AhaObjectPair] = [:]
    
    @State private var laserEntity = Entity()
    @State private var session = ARKitSession()
    @State private var handTracking = HandTrackingProvider()
    @State private var worldTracking = WorldTrackingProvider()
    @State private var latestIndexTipPosition: SIMD3<Float>?
    @State private var lostFrameCount = 0                    // ← 追加
    private let lostFrameThreshold = 5 // 約0.1秒分(90Hz想定)  // ← 追加
    /// 正解オブジェクトにレーザーが連続して当たり始めた時刻。
    @State private var correctTargetHitStartedAt: Date?
    private let correctTargetHoldDuration: TimeInterval = 2.0
    
    @State private var directOcclusionBoxStore = DirectOcclusionBoxStore()
    @State private var coordinateValidationMarkerStore = CoordinateValidationMarkerStore()
    @State private var menuEntityStore = MenuEntityStore()
    @State private var handGestureStore = HandGestureStore()
    @State private var feedbackTargetPosition: SIMD3<Float>?
    
    var body: some View {
        RealityView { content, attachments in
            for def in gameManager.modelDefinitions {
                let pair = AhaObjectPair(id: def.id)
                await pair.loadModels(originalName: def.original, alteredName: def.altered)

                content.add(pair.rootEntity)
                // 4点キャリブレーションが終わるまでモデルは表示しない。
                pair.rootEntity.isEnabled = false
                
                loadedPairs[def.id] = pair
                
                print("🌍 [ロード完了] \(def.id) ローカル位置: \(pair.rootEntity.position)")
            }
            
            if let uiEntity = attachments.entity(for: "GameUI") {
                uiEntity.position = SIMD3<Float>(0, 1.2, -0.5)
                content.add(uiEntity)
                menuEntityStore.entity = uiEntity
            }
            
            let laserMesh = MeshResource.generateCylinder(height: 2.0, radius: 0.002)
            let laserMaterial = UnlitMaterial(color: .red.withAlphaComponent(0.5))
            let laserModel = ModelEntity(mesh: laserMesh, materials: [laserMaterial])
            laserModel.name = "LaserBeam"
            laserModel.transform.rotation = simd_quatf(angle: .pi/2, axis: [1, 0, 0])
            laserModel.position.z = 1.0
            
            laserEntity.addChild(laserModel)
            laserEntity.isEnabled = false
            content.add(laserEntity)
            
            content.add(directOcclusionBoxStore.rootEntity)
            content.add(coordinateValidationMarkerStore.rootEntity)
            
        } update: { content, attachments in
            applyCalibratedObjectPositions()
            syncDirectOcclusionBoxes()
            syncCoordinateValidationMarker()
            updateMenuPresentation()
        } attachments: {
            Attachment(id: "GameUI") {
                ZStack {
                    if !gameManager.isCalibrated {
                        VStack(spacing: 16) {
                            Text("基準点 \(gameManager.nextCalibrationPointNumber) / 4")
                                .font(.title)
                            Text(gameManager.calibrationInstruction)
                                .font(.body)
                            Button("最初から取り直す") {
                                gameManager.restartCalibration()
                            }
                        }
                        .padding()
                        .glassBackgroundEffect()
                    } else if !appModel.multiplayerGame.canEditPlacement {
                        VStack(spacing: 10) {
                            Text("ホストの確定配置を表示中です")
                            Text("微調整とオクルージョンボックスの配置はホスト端末で行います")
                                .font(.caption)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        .glassBackgroundEffect()
                    } else {
                        VStack(spacing: 14) {
                            if gameManager.isOcclusionBoxPlacementMode {
                                Text("40 cm のオクルージョンボックスを棚に重ねるようにドラッグしてください")
                                    .font(.body)
                                Text("水色のガイドは配置完了後に消え、正面以外の5面だけが遮蔽として残ります")
                                    .font(.caption)
                                Button("オクルージョンボックスを追加生成") {
                                    gameManager.requestOcclusionBox()
                                }
                                Button("オクルージョンボックス配置を完了") {
                                    gameManager.finishOcclusionBoxPlacement()
                                }
                                Button("オクルージョンボックスをすべて削除") {
                                    gameManager.clearOcclusionBoxes()
                                }
                            } else if gameManager.isAdjustmentMode {
                                Text("微調整モード：オブジェクトをドラッグして位置を合わせてください")
                                    .font(.body)
                                Button("微調整を完了") {
                                    gameManager.isAdjustmentMode = false
                                }
                                Button("基準配置に戻す") {
                                    gameManager.clearPositionAdjustments()
                                }
                            } else {
                                Button("配置を微調整する") {
                                    gameManager.isAdjustmentMode = true
                                }
                                Button("オクルージョンボックスを生成") {
                                    gameManager.requestOcclusionBox()
                                }
                            }

                            Button(action: {
                                publishCurrentPlacement()
                                appModel.multiplayerGame.requestStartRound()
                            }) {
                                Text("配置を確定してスタート")
                                    .font(.title)
                                    .padding()
                            }
                            .disabled(gameManager.isAdjustmentMode || gameManager.isOcclusionBoxPlacementMode || gameManager.isPositionLocked)
                        }
                        .glassBackgroundEffect()
                        .opacity(gameManager.isPositionLocked ? 0.0 : 1.0)
                    }
                    
                    if gameManager.hasFoundObject {
                        VStack(spacing: 20) {
                            Text("正解！変化したオブジェクトを見つけました！")
                                .font(.extraLargeTitle)
                                .padding()
                                .glassBackgroundEffect()
                            
                            Button(action: {
                                feedbackTargetPosition = nil
                                appModel.multiplayerGame.requestReplay()
                            }) {
                                Text("もう一度遊ぶ（配置をやり直す）")
                                    .font(.title2)
                                    .padding()
                            }
                            .glassBackgroundEffect()
                        }
                    }
                }
            }
        }
        // ==========================================
        // ジェスチャー処理
        // ==========================================
        .gesture(
            DragGesture(minimumDistance: 10)
                .targetedToAnyEntity()
                .onChanged { value in
                    guard gameManager.isCalibrated,
                          appModel.multiplayerGame.canEditPlacement,
                          !gameManager.isPositionLocked else { return }

                    // オクルージョンボックスは配置モード中だけ、仮想物体と同じ操作で直接動かせる。
                    if gameManager.isOcclusionBoxPlacementMode,
                       let boxRoot = findOcclusionBoxRoot(for: value.entity) {
                        moveEntity(boxRoot, with: value)
                        return
                    }

                    guard gameManager.isAdjustmentMode else { return }
                    if let targetRoot = findRootEntity(for: value.entity) {
                        moveEntity(targetRoot, with: value)
                    }
                }
                .onEnded { value in
                    if let boxRoot = findOcclusionBoxRoot(for: value.entity) {
                        dragOffsets.removeValue(forKey: boxRoot.id)
                        publishCurrentPlacement()
                        return
                    }
                    if let targetRoot = findRootEntity(for: value.entity),
                       let modelID = loadedPairs.first(where: { $0.value.rootEntity == targetRoot })?.key {
                        
                        dragOffsets.removeValue(forKey: targetRoot.id)
                        gameManager.savePositionAdjustment(
                            targetRoot.position(relativeTo: nil),
                            for: modelID
                        )
                        publishCurrentPlacement()
                    }
                }
        )
        .gesture(
            RotateGesture3D()
                .simultaneously(with: MagnifyGesture())
                .targetedToAnyEntity()
                .onChanged { value in
                    guard !gameManager.isCalibrated, !gameManager.isPositionLocked else { return }
                    if let targetRoot = findRootEntity(for: value.entity) {
                        
                        if initialOrientations[targetRoot.id] == nil {
                            initialOrientations[targetRoot.id] = targetRoot.orientation
                        }
                        if initialScales[targetRoot.id] == nil {
                            initialScales[targetRoot.id] = targetRoot.scale
                        }
                        
                        if let rotation3D = value.first?.rotation,
                           let startOrientation = initialOrientations[targetRoot.id] {
                            let rotationTransform = Transform(AffineTransform3D(rotation: rotation3D))
                            targetRoot.orientation = startOrientation * rotationTransform.rotation
                        }
                        
                        if let magnification = value.second?.magnification,
                           let startScale = initialScales[targetRoot.id] {
                            targetRoot.scale = startScale * Float(magnification)
                        }
                    }
                }
                .onEnded { value in
                    if let targetRoot = findRootEntity(for: value.entity) {
                        
                        initialOrientations.removeValue(forKey: targetRoot.id)
                        initialScales.removeValue(forKey: targetRoot.id)
                        
                    }
                }
        )
        // ==========================================
        // ARKit セッション (ハンドトラッキングのみ)
        // ==========================================
        .task {
            let authResult = await session.requestAuthorization(for: [.handTracking, .worldSensing])
            guard authResult[.handTracking] == .allowed else { return }
            
            do {
                // WorldAnchorを使わず、軽量なワールドトラッキングで座標系を物理空間へ固定する。
                if authResult[.worldSensing] == .allowed {
                    try await session.run([handTracking, worldTracking])
                } else {
                    try await session.run([handTracking])
                    print("⚠️ worldSensingが未許可のため、位置安定化なしで動作します")
                }
                
                for await update in handTracking.anchorUpdates {
                    let anchor = update.anchor
                    guard anchor.isTracked, anchor.chirality == .right else {
                        await MainActor.run {
                            laserEntity.isEnabled = false
                            gameManager.resetCalibrationFingerTracking()
                            handGestureStore.wasPalmFacingPlayer = false
                            correctTargetHitStartedAt = nil
                        }
                        continue
                    }
                    
                    guard let tip = anchor.handSkeleton?.joint(.indexFingerTip), tip.isTracked else {
                        lostFrameCount += 1
                        await MainActor.run {
                            if lostFrameCount > lostFrameThreshold {
                                laserEntity.isEnabled = false
                            }
                            latestIndexTipPosition = nil
                            gameManager.resetCalibrationFingerTracking()
                            correctTargetHitStartedAt = nil
                        }
                        continue
                    }
                    
                    let getPos: (HandSkeleton.Joint) -> SIMD3<Float> = { joint in
                        let t = matrix_multiply(anchor.originFromAnchorTransform, joint.anchorFromJointTransform)
                        return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
                    }
                    
                    let tipPos = getPos(tip)

                    let palmFacesPlayer: Bool = {
                        guard let indexKnuckle = anchor.handSkeleton?.joint(.indexFingerKnuckle), indexKnuckle.isTracked,
                              let littleKnuckle = anchor.handSkeleton?.joint(.littleFingerKnuckle), littleKnuckle.isTracked,
                              let middleKnuckle = anchor.handSkeleton?.joint(.middleFingerKnuckle), middleKnuckle.isTracked,
                              let wrist = anchor.handSkeleton?.joint(.wrist), wrist.isTracked,
                              let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else {
                            return false
                        }
                        let wristPosition = getPos(wrist)
                        let acrossPalm = getPos(indexKnuckle) - getPos(littleKnuckle)
                        let towardFingers = getPos(middleKnuckle) - wristPosition
                        guard length(acrossPalm) > 0.001, length(towardFingers) > 0.001 else { return false }
                        let palmNormal = normalize(cross(acrossPalm, towardFingers))
                        let devicePosition = SIMD3<Float>(
                            deviceAnchor.originFromAnchorTransform.columns.3.x,
                            deviceAnchor.originFromAnchorTransform.columns.3.y,
                            deviceAnchor.originFromAnchorTransform.columns.3.z
                        )
                        return dot(palmNormal, normalize(devicePosition - wristPosition)) > 0.65
                    }()

                    await MainActor.run {
                        latestIndexTipPosition = tipPos
                        gameManager.updateCalibrationFingerPosition(tipPos)
                        if gameManager.isCalibrated,
                           palmFacesPlayer,
                           !handGestureStore.wasPalmFacingPlayer {
                            gameManager.requestMenuPresentation()
                        }
                        handGestureStore.wasPalmFacingPlayer = palmFacesPlayer
                    }

                    // 配置確定前はレーザーを表示・判定しない。
                    // キャリブレーション中は静止した指先だけを記録する。
                    guard gameManager.isCalibrated, gameManager.isPositionLocked else {
                        await MainActor.run {
                            laserEntity.isEnabled = false
                            correctTargetHitStartedAt = nil
                        }
                        continue
                    }

                    guard let knuckle = anchor.handSkeleton?.joint(.indexFingerKnuckle),
                          knuckle.isTracked else {
                        lostFrameCount += 1
                        await MainActor.run {
                            if lostFrameCount > lostFrameThreshold {
                                laserEntity.isEnabled = false
                                correctTargetHitStartedAt = nil
                            }
                        }
                        continue
                    }

                    let knucklePos = getPos(knuckle)
                    
                    lostFrameCount = 0   // ← 追加：両方取れたので連続ロストカウントをリセット
                    
                    let forwardDirection = normalize(tipPos - knucklePos)
                    let visualDirection = normalize(knucklePos - tipPos)
                    
                    var pointedObjectID: String? = nil
                    
                    await MainActor.run {
                        let radius: Float = 0.15
                        for (id, pair) in loadedPairs {
                            let objectPos = pair.rootEntity.position(relativeTo: nil)
                            let L = objectPos - tipPos
                            
                            let tca = dot(L, forwardDirection)
                            if tca > 0 {
                                let d2 = dot(L, L) - (tca * tca)
                                if d2 <= (radius * radius) {
                                    pointedObjectID = id
                                    break
                                }
                            }
                        }
                        
                        laserEntity.isEnabled = true
                        laserEntity.position = tipPos
                        laserEntity.look(at: tipPos + (visualDirection * 10.0), from: tipPos, relativeTo: nil)
                        
                        if let laserModel = laserEntity.findEntity(named: "LaserBeam") as? ModelEntity {
                            // ヒットの有無は見た目に出さず、ゲーム中の手掛かりにしない。
                            laserModel.model?.materials = [UnlitMaterial(color: .red.withAlphaComponent(0.5))]
                        }
                        
                        let isHoldingCorrectTarget = !gameManager.hasFoundObject
                            && pointedObjectID == gameManager.targetId

                        if isHoldingCorrectTarget {
                            if correctTargetHitStartedAt == nil {
                                correctTargetHitStartedAt = .now
                                print("⏱️ [Correct Hold Start] \(gameManager.targetId): 2秒間レーザーを当て続けてください")
                            } else if let startedAt = correctTargetHitStartedAt,
                                      Date.now.timeIntervalSince(startedAt) >= correctTargetHoldDuration {
                                correctTargetHitStartedAt = nil
                                print("👉 正解！変化したオブジェクト(\(gameManager.targetId))に2秒間レーザーを当てました！")
                                appModel.multiplayerGame.submitAnswer(modelID: gameManager.targetId)
                                // 配置した端末では同期処理が即時反映されるため、目の前へ移動する演出も開始する。
                                if gameManager.hasFoundObject {
                                    presentCorrectAnswer()
                                }
                            }
                        } else {
                            correctTargetHitStartedAt = nil
                        }
                    }
                }
            } catch {
                print("ARKitセッション起動エラー: \(error)")
            }
        }
        .realityViewLayoutBehavior(.fixedSize)
        .volumeBaseplateVisibility(.hidden)
        .onAppear {
            appModel.multiplayerGame.attach(gameManager: gameManager, rpcModel: appModel.rpcModel)
            gameManager.restartCalibration()
        }
        // RealityView.update 中ではなく、キャリブレーション完了後の SwiftUI の
        // 状態遷移として最初の配置を保存する。
        .onChange(of: gameManager.isCalibrated) { _, isCalibrated in
            guard isCalibrated,
                  appModel.multiplayerGame.canEditPlacement,
                  loadedPairs.count == gameManager.modelDefinitions.count
            else { return }
            publishCurrentPlacement()
        }
        // 透明度の変更は RealityView.update の外で行う。
        // これにより、SwiftUI のビュー更新中にコンポーネントを更新する警告を防ぐ。
        .onChange(of: gameManager.transitionProgress) { _, _ in
            applyModelProgress()
        }
        .onChange(of: gameManager.targetId) { _, _ in
            applyModelProgress()
        }
        .onChange(of: loadedPairs.count) { _, _ in
            applyModelProgress()
        }
        .onDisappear {
            latestIndexTipPosition = nil
            feedbackTargetPosition = nil
            correctTargetHitStartedAt = nil
            gameManager.playAgain()
        }
    }
    
    
    
    // ヘルパー関数
    private func findRootEntity(for entity: Entity) -> Entity? {
        for pair in loadedPairs.values {
            var currentEntity: Entity? = entity
            while let current = currentEntity {
                if current == pair.rootEntity {
                    return pair.rootEntity
                }
                currentEntity = current.parent
            }
        }
        return nil
    }

    private func findOcclusionBoxRoot(for entity: Entity) -> Entity? {
        var currentEntity: Entity? = entity
        while let current = currentEntity {
            if directOcclusionBoxStore.boxes.contains(where: { $0 == current }) {
                return current
            }
            currentEntity = current.parent
        }
        return nil
    }

    private func moveEntity(_ entity: Entity, with value: EntityTargetValue<DragGesture.Value>) {
        if dragOffsets[entity.id] == nil {
            dragOffsets[entity.id] = entity.position(relativeTo: nil)
        }
        guard let startPosition = dragOffsets[entity.id] else { return }
        let translationInScene = value.convert(value.translation3D, from: .local, to: .scene)
        let offset = SIMD3<Float>(
            Float(translationInScene.x),
            Float(translationInScene.y),
            Float(translationInScene.z)
        )
        entity.setPosition(startPosition + offset, relativeTo: nil)
    }

    /// 要求数に合わせて、ユーザーが直接ドラッグする40 cmの正面開口ボックスを同期する。
    /// Storeは参照型のため、RealityViewの更新中に@Stateを書き換えずに済む。
    private func syncDirectOcclusionBoxes() {
        // 参加端末では、ホストから座標変換済みで届いたボックスだけを再現する。
        if gameManager.hasSharedPlacement {
            let remoteBoxes = gameManager.sharedOcclusionBoxTransforms
            let remoteIDs = Set(remoteBoxes.keys)

            for box in directOcclusionBoxStore.boxes.reversed() where
                !remoteIDs.contains(directOcclusionBoxStore.identifiers[box.id] ?? UUID()) {
                directOcclusionBoxStore.identifiers.removeValue(forKey: box.id)
                box.removeFromParent()
                directOcclusionBoxStore.boxes.removeAll { $0 == box }
            }

            for (id, matrix) in remoteBoxes {
                if let box = directOcclusionBoxStore.boxes.first(where: {
                    directOcclusionBoxStore.identifiers[$0.id] == id
                }) {
                    box.setTransformMatrix(matrix, relativeTo: nil)
                } else {
                    let (box, guide) = makeDirectOcclusionBox(at: .zero)
                    box.setTransformMatrix(matrix, relativeTo: nil)
                    guide.isEnabled = false
                    directOcclusionBoxStore.rootEntity.addChild(box)
                    directOcclusionBoxStore.boxes.append(box)
                    directOcclusionBoxStore.guideEntities.append(guide)
                    directOcclusionBoxStore.identifiers[box.id] = id
                }
            }
            return
        }

        let requestedCount = gameManager.requestedOcclusionBoxCount

        while directOcclusionBoxStore.boxes.count > requestedCount {
            let box = directOcclusionBoxStore.boxes.removeLast()
            directOcclusionBoxStore.identifiers.removeValue(forKey: box.id)
            box.removeFromParent()
            _ = directOcclusionBoxStore.guideEntities.popLast()
        }

        while directOcclusionBoxStore.boxes.count < requestedCount {
            // 生成時は指先の近くに出す。指先が未取得なら正解モデルの位置を使う。
            let position = latestIndexTipPosition
                ?? gameManager.calibratedPosition(for: gameManager.targetId)
                ?? SIMD3<Float>(0, 1, -1)
            let (box, guide) = makeDirectOcclusionBox(at: position)
            directOcclusionBoxStore.rootEntity.addChild(box)
            directOcclusionBoxStore.boxes.append(box)
            directOcclusionBoxStore.guideEntities.append(guide)
            directOcclusionBoxStore.identifiers[box.id] = UUID()
        }

        let showGuide = gameManager.isOcclusionBoxPlacementMode
        for guide in directOcclusionBoxStore.guideEntities {
            guide.isEnabled = showGuide
        }
    }

    /// 40 cm四方・奥行き40 cmの箱。正面（ローカル -Z 面）は開口し、他の5面だけが遮蔽する。
    private func makeDirectOcclusionBox(at position: SIMD3<Float>) -> (box: Entity, guide: Entity) {
        let box = Entity()
        box.name = "DirectOcclusionBox"
        box.setPosition(position, relativeTo: nil)
        // 棚座標系の正面に開口（ローカル -Z 面）が向くよう、Y軸に -90° 補正する。
        box.orientation = gameManager.calibrationOrientation * simd_quatf(
            angle: -.pi / 2,
            axis: SIMD3<Float>(0, 1, 0)
        )
        box.components.set(InputTargetComponent())
        box.components.set(CollisionComponent(shapes: [
            ShapeResource.generateBox(size: SIMD3<Float>(repeating: 0.4))
        ]))

        let guide = Entity()
        guide.name = "OcclusionBoxGuide"
        let half: Float = 0.2
        let x = SIMD3<Float>(0.4, 0, 0)
        let y = SIMD3<Float>(0, 0.4, 0)
        let z = SIMD3<Float>(0, 0, 0.4)

        // -Z（正面）を空け、+Zの奥板と4つの側面を作る。
        let panels: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(-half, -half, half), x, y), // 奥
            (SIMD3(-half, -half, -half), z, y), // 左
            (SIMD3(half, -half, -half), z, y), // 右
            (SIMD3(-half, half, -half), x, z), // 上
            (SIMD3(-half, -half, -half), x, z), // 下
        ]

        for (origin, right, down) in panels {
            guard let mesh = makeDoubleSidedRectangleMesh(right: right, down: down) else { continue }
            let occluder = ModelEntity(mesh: mesh, materials: [OcclusionMaterial()])
            occluder.position = origin
            box.addChild(occluder)

            // 配置時だけ見える、ドラッグ位置合わせ用の半透明ガイド。
            let guidePanel = ModelEntity(
                mesh: mesh,
                materials: [UnlitMaterial(color: .cyan.withAlphaComponent(0.16))]
            )
            guidePanel.position = origin
            guide.addChild(guidePanel)
        }
        box.addChild(guide)
        return (box, guide)
    }

    private func makeDoubleSidedRectangleMesh(
        right: SIMD3<Float>,
        down: SIMD3<Float>
    ) -> MeshResource? {
        guard length(cross(right, down)) > 0.0001 else { return nil }
        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffers.Positions([.zero, right, down, right + down])
        descriptor.primitives = .triangles([0, 2, 1, 1, 2, 3, 0, 1, 2, 1, 3, 2])
        return try? MeshResource.generate(from: [descriptor])
    }

    private func applyCalibratedObjectPositions() {
        for (modelID, pair) in loadedPairs {
            if let sharedTransform = gameManager.sharedTransform(for: modelID) {
                pair.rootEntity.setTransformMatrix(sharedTransform, relativeTo: nil)
                if gameManager.hasFoundObject,
                   modelID == gameManager.targetId,
                   let feedbackTargetPosition {
                    pair.rootEntity.setPosition(feedbackTargetPosition, relativeTo: nil)
                }
                pair.rootEntity.isEnabled = true
                continue
            }
            guard let position = gameManager.calibratedPosition(for: modelID) else {
                pair.rootEntity.isEnabled = false
                continue
            }
            // 基準点は ARKit のワールド座標で取得しているため、親のローカル座標へ
            // 代入せず、同じワールド座標系 (nil) で配置する。
            // 正解後だけは対象をプレイヤーの前に見せ、次のゲームでは必ず基準位置へ戻す。
            let displayPosition = (gameManager.hasFoundObject && modelID == gameManager.targetId)
                ? (feedbackTargetPosition ?? position)
                : position
            pair.rootEntity.setPosition(displayPosition, relativeTo: nil)
            pair.rootEntity.scale = gameManager.scale(for: modelID)
            pair.rootEntity.orientation = gameManager.orientation(for: modelID)
            pair.rootEntity.isEnabled = true
        }
    }

    /// ホストが共有完了直後に生成した球＋立方体を、参加端末では受信済み変換で再現する。
    private func syncCoordinateValidationMarker() {
        if let sharedTransform = gameManager.sharedCoordinateValidationMarkerTransform {
            let marker = coordinateValidationMarkerStore.markerEntity ?? makeCoordinateValidationMarker()
            if marker.parent == nil {
                coordinateValidationMarkerStore.rootEntity.addChild(marker)
                coordinateValidationMarkerStore.markerEntity = marker
            }
            marker.setTransformMatrix(sharedTransform, relativeTo: nil)
            marker.isEnabled = true
            return
        }

        guard gameManager.isCoordinateValidationMarkerRequested,
              appModel.multiplayerGame.canEditPlacement
        else {
            coordinateValidationMarkerStore.markerEntity?.isEnabled = false
            return
        }

        // ホストは基準オブジェクトの少し上に生成する。ここで生成された完全変換を次のRPCへ載せる。
        if coordinateValidationMarkerStore.markerEntity == nil {
            let marker = makeCoordinateValidationMarker()
            let basePosition = loadedPairs[gameManager.targetId]?.rootEntity.position(relativeTo: nil)
                ?? loadedPairs.values.first?.rootEntity.position(relativeTo: nil)
                ?? SIMD3<Float>(0, 1, -1)
            marker.setPosition(basePosition + SIMD3<Float>(0, 0.22, 0), relativeTo: nil)
            coordinateValidationMarkerStore.rootEntity.addChild(marker)
            coordinateValidationMarkerStore.markerEntity = marker
            print("🧭 [座標共有確認] ホストに検証マーカーを生成: \(marker.position(relativeTo: nil))")
            publishCurrentPlacement()
        }
        coordinateValidationMarkerStore.markerEntity?.isEnabled = true
    }

    private func makeCoordinateValidationMarker() -> Entity {
        let marker = Entity()
        marker.name = "CoordinateValidationMarker"

        let sphere = ModelEntity(
            mesh: .generateSphere(radius: 0.06),
            materials: [UnlitMaterial(color: .magenta)]
        )
        sphere.name = "CoordinateValidationSphere"
        sphere.position = SIMD3<Float>(0, 0.08, 0)

        let box = ModelEntity(
            mesh: .generateBox(size: 0.10),
            materials: [UnlitMaterial(color: .yellow)]
        )
        box.name = "CoordinateValidationBox"
        box.position = SIMD3<Float>(0.14, 0, 0)

        marker.addChild(sphere)
        marker.addChild(box)
        return marker
    }

    /// 正解モデルだけを変化後モデルへ徐々に切り替える。
    /// SwiftUI の RealityView.update 中ではなく、観測値の変更後に実行する。
    private func applyModelProgress() {
        for (modelID, pair) in loadedPairs {
            pair.updateProgress(
                modelID == gameManager.targetId ? gameManager.transitionProgress : 0
            )
        }
    }

    /// 現在表示しているAさんの最終ワールド変換を、送信前の正本として保存する。
    /// RPC Kit がBさんへの送信時にA→Bのアフィン行列を掛ける。
    private func publishCurrentPlacement() {
        guard appModel.multiplayerGame.canEditPlacement else { return }
        let objects = loadedPairs.map { modelID, pair in
            AhaObjectPlacement(
                objectID: modelID,
                matrix: pair.rootEntity.transformMatrix(relativeTo: nil)
            )
        }
        let boxes = directOcclusionBoxStore.boxes.compactMap { box -> AhaOcclusionBoxPlacement? in
            guard let id = directOcclusionBoxStore.identifiers[box.id] else { return nil }
            return AhaOcclusionBoxPlacement(
                id: id,
                matrix: box.transformMatrix(relativeTo: nil)
            )
        }
        appModel.multiplayerGame.updateAuthoritativePlacement(
            .init(
                objects: objects,
                occlusionBoxes: boxes,
                coordinateValidationMarker: coordinateValidationMarkerStore.markerEntity?
                    .transformMatrix(relativeTo: nil)
            )
        )
    }

    /// 手のひらジェスチャーで要求されたときだけ、UIを視界前方へ表示する。
    /// 追従し続けないため、表示後のボタン操作が安定する。
    private func updateMenuPresentation() {
        guard let menuEntity = menuEntityStore.entity else { return }
        menuEntity.isEnabled = gameManager.isMenuVisible
        guard gameManager.isMenuVisible,
              menuEntityStore.lastPresentationRequest != gameManager.menuPresentationRequest,
              let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else { return }
        let transform = deviceAnchor.originFromAnchorTransform
        let devicePosition = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let forward = -normalize(SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
        let menuPosition = devicePosition + forward * 0.9 + SIMD3<Float>(0, 0.15, 0)
        menuEntity.setPosition(menuPosition, relativeTo: nil)
        menuEntity.look(at: devicePosition, from: menuPosition, relativeTo: nil)
        // SwiftUI Attachment の表面は look(at:) の前方と逆を向くため、毎回180°補正する。
        menuEntity.orientation = menuEntity.orientation * simd_quatf(
            angle: .pi,
            axis: SIMD3<Float>(0, 1, 0)
        )
        menuEntityStore.lastPresentationRequest = gameManager.menuPresentationRequest
    }

    /// 正解時、対象モデルを視界の前へ移し、同じ追従メニューに正解メッセージを出す。
    private func presentCorrectAnswer() {
        guard let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else {
            gameManager.hasFoundObject = true
            return
        }
        let transform = deviceAnchor.originFromAnchorTransform
        let devicePosition = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let forward = -normalize(SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
        feedbackTargetPosition = devicePosition + forward * 0.65 + SIMD3<Float>(0, -0.18, 0)
        gameManager.hasFoundObject = true
        gameManager.requestMenuPresentation()
    }
}
