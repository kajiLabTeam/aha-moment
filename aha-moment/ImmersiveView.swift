//
//  ImmersiveView.swift
//  aha-moment
//
//  Created by k24052kk on 2026/07/31.
//

import SwiftUI
import RealityKit
import RealityKitContent
import ARKit

struct ImmersiveView: View {
    
    // 既存の状態変数
    @State var count = 0
    @State var isActive: Bool = false
    @State var initialScale: SIMD3<Float> = .init(repeating: 1.0)
    @State var initialOrientation: simd_quatf = simd_quatf(
        vector: .init(repeating: 0.0)
    )
    
    // --- すり替え（クロスフェード）用の状態変数 ---
    @State private var isShowingModel2 = false
    @State private var transitionProgress: Float = 0.0
    @State private var isAnimating = false
    
    // ドラッグ開始時の「指とオブジェクトのズレ」を記憶する変数
    @State private var dragOffset: SIMD3<Float>? = nil
    
    // ゲームの進行状態を管理する変数
    @State private var isPositionLocked = false
    @State private var hasFoundObject = false
    
    // エンティティ群
    @State private var modelContainer = Entity()
    @State private var laserEntity = Entity()
    
    // ハンドトラッキング
    let session = ARKitSession()
    let handTracking = HandTrackingProvider()
    
    var body: some View {
        
        RealityView { content, attachments in
                    // 1. 親コンテナの配置
                    modelContainer.position = SIMD3(x: 0, y: 1.0, z: -1.0)
                    content.add(modelContainer)
                    
                    // 2. モデル1の読み込み
                    if let model1 = try? await Entity(named: "model3.usdz") {
                        model1.name = "Model1"
                        model1.generateCollisionShapes(recursive: true)
                        model1.components.set(InputTargetComponent())
                        model1.components.set(OpacityComponent(opacity: 1.0))
                        modelContainer.addChild(model1)
                    }
                    
                    // 3. モデル2の読み込み
                    if let model2 = try? await Entity(named: "model3_sized_red.usdz") {
                        model2.name = "Model2"
                        model2.generateCollisionShapes(recursive: true)
                        model2.components.set(InputTargetComponent())
                        model2.components.set(OpacityComponent(opacity: 0.0))
                        modelContainer.addChild(model2)
                    }
                    
                    // 🚨 修正: ここにあった attachments.entity(...) の処理を下の update ブロックに移動しました
                    
                    // 4. レーザー光線の見た目を作成
                    let laserMesh = MeshResource.generateCylinder(height: 2.0, radius: 0.002)
                    let laserMaterial = UnlitMaterial(color: .red.withAlphaComponent(0.5))
                    let laserModel = ModelEntity(mesh: laserMesh, materials: [laserMaterial])
                    laserModel.name = "LaserBeam"
                    // 円柱をZ軸（前方向）に倒して、指先から真っ直ぐ伸びるように調整
                    laserModel.transform.rotation = simd_quatf(angle: .pi/2, axis: [1, 0, 0])
                    laserModel.position.z = 1.0 // 2mの棒の中心を1m前にずらし、根元を指に合わせる
                    laserEntity.addChild(laserModel)
                    laserEntity.isEnabled = false // 最初は隠しておく
                    content.add(laserEntity)
                    
                } update: { content, attachments in
                    // --- 進行度に応じて透明度をリアルタイムに更新 ---
                    if let m1 = modelContainer.findEntity(named: "Model1"),
                       let m2 = modelContainer.findEntity(named: "Model2") {
                        
                        m1.components[OpacityComponent.self]?.opacity = 1.0 - transitionProgress
                        m2.components[OpacityComponent.self]?.opacity = transitionProgress
                    }
                    
                    // 🌟 修正: アタッチメント（UIボタン）はここで読み込むのが最も確実です
                    if let uiEntity = attachments.entity(for: "GameUI") {
                        // まだ親コンテナに追加されていなければ追加する（初回のみ実行される）
                        if uiEntity.parent == nil {
                            uiEntity.position = SIMD3<Float>(0, 0.4, 0)
                            modelContainer.addChild(uiEntity)
                        }
                    }
                    
                } attachments: {
                    Attachment(id: "GameUI") {
                        ZStack {
                            Button(action: {
                                isPositionLocked = true
                                startTransition()
                            }) {
                                Text("配置を確定してスタート")
                                    .font(.title)
                                    .padding()
                            }
                            .glassBackgroundEffect()
                            .opacity(isPositionLocked ? 0.0 : 1.0)
                            .disabled(isPositionLocked)
                            
                            if hasFoundObject {
                                Text("正解！よく見つけましたね！")
                                    .font(.extraLargeTitle)
                                    .padding()
                                    .glassBackgroundEffect()
                            }
                        }
                    }
                }
        // --- ジェスチャー処理（ドラッグでの配置用） ---
        .gesture(
            DragGesture(minimumDistance: 10)
                .targetedToAnyEntity()
                .onChanged { value in
                    guard !isPositionLocked else { return }
                    
                    let fingerScenePos = value.convert(value.location3D, from: .local, to: .scene)
                    
                    if dragOffset == nil {
                        // 🌟 修正: 親コンテナの座標を直接基準にする
                        dragOffset = modelContainer.position - fingerScenePos
                    }
                    
                    if let offset = dragOffset {
                        // 🌟 修正: 親コンテナを直接動かすことで、モデル1も2も一緒にくっついてくる
                        modelContainer.position = fingerScenePos + offset
                    }
                }
                .onEnded { _ in
                    dragOffset = nil
                }
        )
        // --- 指差し（ハンドトラッキング）の監視タスク ---
        .task {
            let authResult = await session.requestAuthorization(for: [.handTracking])
            guard authResult[.handTracking] == .allowed else { return }
            
            do {
                try await session.run([handTracking])
                var wasPointing = false
                
                for await update in handTracking.anchorUpdates {
                    let anchor = update.anchor
                    
                    guard anchor.isTracked, anchor.chirality == .right else { continue }
                    
                    // 🌟 修正: 指差し判定のために「中指(middle)」と「手首(wrist)」の関節も追加取得
                    guard let tip = anchor.handSkeleton?.joint(.indexFingerTip),
                          let knuckle = anchor.handSkeleton?.joint(.indexFingerKnuckle),
                          let thumb = anchor.handSkeleton?.joint(.thumbTip),
                          let middle = anchor.handSkeleton?.joint(.middleFingerTip),
                          let wrist = anchor.handSkeleton?.joint(.wrist),
                          tip.isTracked, knuckle.isTracked, thumb.isTracked, middle.isTracked, wrist.isTracked else {
                        await MainActor.run { laserEntity.isEnabled = false }
                        continue
                    }
                    
                    // 関節のワールド座標を計算するヘルパー関数
                    let getPos: (HandSkeleton.Joint) -> SIMD3<Float> = { joint in
                        let t = matrix_multiply(anchor.originFromAnchorTransform, joint.anchorFromJointTransform)
                        return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
                    }
                    
                    let tipPos = getPos(tip)
                    let knucklePos = getPos(knuckle)
                    let thumbPos = getPos(thumb)
                    let middlePos = getPos(middle)
                    let wristPos = getPos(wrist)
                    
                    // 🌟 追加: 指差しポーズの厳密な判定
                    let isPinching = distance(tipPos, thumbPos) < 0.03
                    let indexToWrist = distance(tipPos, wristPos)
                    let middleToWrist = distance(middlePos, wristPos)
                    
                    // 人差し指が手首から遠く(伸びている)、中指が手首に近い(曲げている)なら指差しポーズ
                    let isPointingPose = indexToWrist > (middleToWrist + 0.04)
                    
                    if isPinching || !isPointingPose {
                        // 指差しポーズでない時はレーザーを消して無視する
                        await MainActor.run { laserEntity.isEnabled = false }
                        wasPointing = false
                        continue
                    }
                    
                    let pointDirection = normalize(tipPos - knucklePos)
                    let objectPos = await MainActor.run { modelContainer.position }
                    let radius: Float = 0.3
                    
                    let L = objectPos - tipPos
                    let tca = dot(L, pointDirection)
                    var isPointingNow = false
                    
                    if tca > 0 {
                        let d2 = dot(L, L) - (tca * tca)
                        if d2 <= (radius * radius) {
                            isPointingNow = true // 命中！
                        }
                    }
                    
                    await MainActor.run {
                        laserEntity.isEnabled = true
                        laserEntity.position = tipPos
                        laserEntity.look(at: tipPos + pointDirection, from: tipPos, relativeTo: nil)
                        
                        if let laserModel = laserEntity.findEntity(named: "LaserBeam") as? ModelEntity {
                            let color: UIColor = isPointingNow ? .green : .red.withAlphaComponent(0.5)
                            laserModel.model?.materials = [UnlitMaterial(color: color)]
                        }
                    }
                    
                    if isPointingNow && !wasPointing {
                        await MainActor.run {
                            if isPositionLocked && !hasFoundObject {
                                print("👉 変化したオブジェクトを指差して見つけました！")
                                hasFoundObject = true
                            }
                        }
                    }
                    wasPointing = isPointingNow
                }
            } catch {
                print("ハンドトラッキング起動エラー: \(error)")
            }
        }
        .realityViewLayoutBehavior(.fixedSize)
        .volumeBaseplateVisibility(.hidden)
    }
    
    // --- 滑らかに透明度を変化させる非同期関数 ---
    private func startTransition() {
        isAnimating = true
        let targetProgress: Float = isShowingModel2 ? 0.0 : 1.0
        let startProgress: Float = transitionProgress
        
        let duration: TimeInterval = 20.0
        let fps = 30
        let steps = Int(duration * Double(fps))
        
        let interval = duration / Double(steps)
        let stepValue = (targetProgress - startProgress) / Float(steps)
        
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            
            for _ in 0..<steps {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await MainActor.run {
                    transitionProgress += stepValue
                }
            }
            
            await MainActor.run {
                transitionProgress = targetProgress
                isShowingModel2.toggle()
                isAnimating = false
            }
        }
    }
}

#Preview(immersionStyle: .mixed) {
    ImmersiveView()
        .environment(AppModel())
}
