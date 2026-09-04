import SwiftUI
import RealityKit
import RealityKitContent
import ARKit

struct ImmersiveView: View {
    @Environment(GameManager.self) var gameManager
    
    @State private var dragOffsets: [UInt64: SIMD3<Float>] = [:]
    @State private var initialScales: [UInt64: SIMD3<Float>] = [:]
    @State private var initialOrientations: [UInt64: simd_quatf] = [:]
    
    @State private var loadedPairs: [String: AhaObjectPair] = [:]
    
    @State private var laserEntity = Entity()
    @State private var session = ARKitSession()
    @State private var handTracking = HandTrackingProvider()
    @State private var latestIndexTipPosition: SIMD3<Float>?
    @State private var lostFrameCount = 0                    // ← 追加
    private let lostFrameThreshold = 5 // 約0.1秒分(90Hz想定)  // ← 追加
    
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
            
        } update: { content, attachments in
            applyCalibratedObjectPositions()
            if let targetPair = loadedPairs[gameManager.targetId] {
                targetPair.updateProgress(gameManager.transitionProgress)
            }
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
                    } else {
                        Button(action: {
                            gameManager.isPositionLocked = true
                            gameManager.startTransition()
                        }) {
                            Text("配置を確定してスタート")
                                .font(.title)
                                .padding()
                        }
                        .glassBackgroundEffect()
                        .opacity(gameManager.isPositionLocked ? 0.0 : 1.0)
                        .disabled(gameManager.isPositionLocked)
                    }
                    
                    if gameManager.hasFoundObject {
                        VStack(spacing: 20) {
                            Text("正解！よく見つけましたね！")
                                .font(.extraLargeTitle)
                                .padding()
                                .glassBackgroundEffect()
                            
                            Button(action: {
                                gameManager.isPositionLocked = false
                                gameManager.hasFoundObject = false
                                gameManager.transitionProgress = 0.0
                                gameManager.pickRandomTarget()
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
                    // キャリブレーション後のモデル位置は研究室座標から決定するため、
                    // ドラッグでは動かさない。
                    guard !gameManager.isCalibrated, !gameManager.isPositionLocked else { return }
                    if let targetRoot = findRootEntity(for: value.entity) {
                        
                        if dragOffsets[targetRoot.id] == nil {
                            dragOffsets[targetRoot.id] = targetRoot.position
                        }
                        
                        if let startPos = dragOffsets[targetRoot.id] {
                            // 🌟 修正: ポイント単位をメートル(Scene空間ベクトル)に正しく変換する
                            let translationInScene = value.convert(value.translation3D, from: .local, to: .scene)
                            let offset = SIMD3<Float>(Float(translationInScene.x), Float(translationInScene.y), Float(translationInScene.z))
                            
                            targetRoot.position = startPos + offset
                        }
                    }
                }
                .onEnded { value in
                    if let targetRoot = findRootEntity(for: value.entity) {
                        
                        dragOffsets.removeValue(forKey: targetRoot.id)
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
            let authResult = await session.requestAuthorization(for: [.handTracking])
            guard authResult[.handTracking] == .allowed else { return }
            
            do {
                try await session.run([handTracking])
                
                var wasPointing = false
                for await update in handTracking.anchorUpdates {
                    let anchor = update.anchor
                    guard anchor.isTracked, anchor.chirality == .right else {
                        await MainActor.run {
                            laserEntity.isEnabled = false
                            gameManager.resetCalibrationFingerTracking()
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
                        }
                        continue
                    }
                    
                    let getPos: (HandSkeleton.Joint) -> SIMD3<Float> = { joint in
                        let t = matrix_multiply(anchor.originFromAnchorTransform, joint.anchorFromJointTransform)
                        return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
                    }
                    
                    let tipPos = getPos(tip)

                    await MainActor.run {
                        latestIndexTipPosition = tipPos
                        gameManager.updateCalibrationFingerPosition(tipPos)
                    }

                    // キャリブレーション中はレーザーを使わず、静止した指先だけを記録する。
                    guard gameManager.isCalibrated else {
                        await MainActor.run { laserEntity.isEnabled = false }
                        continue
                    }

                    guard let knuckle = anchor.handSkeleton?.joint(.indexFingerKnuckle),
                          knuckle.isTracked else {
                        lostFrameCount += 1
                        await MainActor.run {
                            if lostFrameCount > lostFrameThreshold {
                                laserEntity.isEnabled = false
                                wasPointing = false
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
                        let radius: Float = 0.3
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
                        
                        let isPointingNow = (pointedObjectID != nil)
                        laserEntity.isEnabled = true
                        laserEntity.position = tipPos
                        laserEntity.look(at: tipPos + (visualDirection * 10.0), from: tipPos, relativeTo: nil)
                        
                        if let laserModel = laserEntity.findEntity(named: "LaserBeam") as? ModelEntity {
                            let color: UIColor = isPointingNow ? .green : .red.withAlphaComponent(0.5)
                            laserModel.model?.materials = [UnlitMaterial(color: color)]
                        }
                        
                        if isPointingNow && !wasPointing {
                            if gameManager.isPositionLocked && !gameManager.hasFoundObject {
                                if pointedObjectID == gameManager.targetId {
                                    print("👉 正解！変化したオブジェクト(\(gameManager.targetId))を見つけました！")
                                    gameManager.hasFoundObject = true
                                }
                            }
                        }
                        wasPointing = isPointingNow
                    }
                }
            } catch {
                print("ARKitセッション起動エラー: \(error)")
            }
        }
        .realityViewLayoutBehavior(.fixedSize)
        .volumeBaseplateVisibility(.hidden)
        .onAppear {
            gameManager.restartCalibration()
        }
        .onDisappear {
            latestIndexTipPosition = nil
            gameManager.pickRandomTarget()
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

    private func applyCalibratedObjectPositions() {
        for (modelID, pair) in loadedPairs {
            guard let position = gameManager.calibratedPosition(for: modelID) else {
                pair.rootEntity.isEnabled = false
                continue
            }
            // 基準点は ARKit のワールド座標で取得しているため、親のローカル座標へ
            // 代入せず、同じワールド座標系 (nil) で配置する。
            pair.rootEntity.setPosition(position, relativeTo: nil)
            pair.rootEntity.scale = gameManager.scale(for: modelID)
            pair.rootEntity.orientation = gameManager.orientation(for: modelID)
            pair.rootEntity.isEnabled = true
        }
    }
}

// 基準点を４つ設定する方法でいくmain
