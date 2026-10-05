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

            Text("マルチプレイ")
                .font(.title2)
            Text(appModel.multiplayerGame.isHosting ? "この端末はゲームホストです" : "参加者モードです")
            HStack {
                Button(appModel.multiplayerGame.isHosting ? "この端末をゲームホストにする" : "この端末へゲームホストを移す") {
                    appModel.multiplayerGame.becomeHost()
                }
                Button("既存ホストに参加") {
                    appModel.multiplayerGame.joinExistingHost()
                }
            }

            Divider()

            SharedCoordinateSetupView(
                appModel: appModel,
                game: appModel.multiplayerGame
            )
        }
        .padding()
        .onAppear {
            appModel.multiplayerGame.attach(gameManager: gameManager, rpcModel: appModel.rpcModel)
        }
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
