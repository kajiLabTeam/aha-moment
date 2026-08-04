//
//  ImmersiveView.swift
//  aha-moment
//
//  Created by k24052kk on 2026/07/31.
//

import SwiftUI
import RealityKit
import RealityKitContent

struct ImmersiveView: View {
    // 既存の状態変数
    @State var count = 0
    @State var isActive: Bool = false
    @State var initialScale: SIMD3<Float> = .init(repeating: 1.0)
    @State var initialOrientation: simd_quatf = simd_quatf(
        vector: .init(repeating: 0.0)
    )
    
    // --- 追加：すり替え（クロスフェード）用の状態変数 ---
    @State private var isShowingModel2 = false
    @State private var transitionProgress: Float = 0.0
    @State private var isAnimating = false // 連続タップ防止用フラグ

    var body: some View {
        
        RealityView { content in
            // --- 1. モデル1の読み込み ---
            // ※ "model1.usdz" の部分は実際のファイル名に合わせて変更してください
            if let model1 = try? await Entity(named: "model3.usdz") {
                model1.name = "Model1"
                
                // タッチ（ジェスチャー）を受け付けるための当たり判定と入力設定
                model1.generateCollisionShapes(recursive: true)
                model1.components.set(InputTargetComponent())
                
                // 初期状態は不透明（1.0）
                model1.components.set(OpacityComponent(opacity: 1.0))
                content.add(model1)
            }
            
            // --- 2. モデル2の読み込み ---
            // ※ "model2.usdz" の部分は実際のファイル名に合わせて変更してください
            if let model2 = try? await Entity(named: "model3_sized_red.usdz") {
                model2.name = "Model2"
                
                // モデル2が表示された後もタッチ判定を持たせるための設定
                model2.generateCollisionShapes(recursive: true)
                model2.components.set(InputTargetComponent())
                
                // 初期状態は透明（0.0）
                model2.components.set(OpacityComponent(opacity: 0.0))
                content.add(model2)
            }
            
        } update: { content in
            // --- 3. 進行度に応じて透明度をリアルタイムに更新 ---
            if let m1 = content.entities.first(where: { $0.name == "Model1" }),
               let m2 = content.entities.first(where: { $0.name == "Model2" }) {
                
                // モデル1は徐々に消え、モデル2は徐々に現れる
                m1.components[OpacityComponent.self]?.opacity = 1.0 - transitionProgress
                m2.components[OpacityComponent.self]?.opacity = transitionProgress
            }
        }
        // --- 4. ドラッグジェスチャーをタップジェスチャーに変更 ---
        .gesture(
            TapGesture()
                .targetedToAnyEntity()
                .onEnded { _ in
                    // アニメーション動作中でなければ、すり替えを開始する
                    if !isAnimating {
                        startTransition()
                    }
                }
        )
        .realityViewLayoutBehavior(.fixedSize)
        .volumeBaseplateVisibility(.hidden)
        
    }
    
    // --- 5. 滑らかに透明度を変化させる非同期関数 ---
    private func startTransition() {
        isAnimating = true
        let targetProgress: Float = isShowingModel2 ? 0.0 : 1.0
        let startProgress: Float = transitionProgress
        
        let duration: TimeInterval = 20.0 // 変化にかける時間（2秒）
        let steps = 60 // 1秒あたりの更新回数（フレーム数）の目安
        
        let interval = duration / Double(steps)
        let stepValue = (targetProgress - startProgress) / Float(steps)
        
        Task {
            for _ in 0..<steps {
                // 指定時間待機
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                
                // メインスレッドで数値を更新
                await MainActor.run {
                    transitionProgress += stepValue
                }
            }
            
            // 最終的な値を正確に合わせ、状態を反転
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
