//
//  ContentView.swift
//  aha-moment
//
//  Created by k24052kk on 2026/07/31.
//

import SwiftUI
import RealityKit
import RealityKitContent
import ImmersiveRPCKit

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(GameManager.self) private var gameManager

    var body: some View {
        VStack(spacing: 20) {
            Text("Aha Moment")
                .font(.largeTitle)

            ToggleImmersiveSpaceButton()

            Divider()

            Text("共同プレイの準備")
                .font(.title2)
            Text("先に実物へ配置する人は、下のボタンを押してから Immersive Space で配置を完了してください。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("この端末で実物に合わせて配置する") {
                appModel.multiplayerGame.beginPlacement()
            }
            .disabled(appModel.multiplayerGame.hasPlacementOwner)

            Divider()

            Text("2人で座標を合わせる")
                .font(.title2)
            Text("両端末で以下の Immersive RPC Kit の案内に従い、同じ相手を選択して指合わせを行ってください。変換完了後は、両端末で「設定を完了しました」を押してアプリ操作へ戻ります。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            // Immersive RPC Kit が提供する標準の座標共有 UI。
            TransformationMatrixPreparationView(
                rpcModel: appModel.rpcModel,
                coordinateTransforms: appModel.coordinateTransforms
            )
        }
        .padding()
        .onAppear {
            appModel.multiplayerGame.attach(gameManager: gameManager, rpcModel: appModel.rpcModel)
        }
        // PreparationState は Equatable ではないため、表示名を使って全段階を監視する。
        // これにより、座標共有がどの画面・段階で止まったかをログで追跡できる。
        .onChange(of: String(describing: appModel.coordinateTransforms.session.state)) { oldState, newState in
            appModel.multiplayerGame.coordinateSharingStateDidChange(
                from: oldState,
                to: newState
            )
        }
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
