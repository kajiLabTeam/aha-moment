//
//  aha_momentApp.swift
//  aha-moment
//
//  Created by k24052kk on 2026/07/31.
//

import SwiftUI
import ImmersiveRPCKit

@main
struct aha_momentApp: App {
    
    @State private var appModel = AppModel()
    
    // 🌟 追加: アプリ全体で1つの GameManager を保持する
    @State private var gameManager = GameManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .environment(gameManager) // 🌟 ContentViewに渡す
        }
        
        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            SharedCoordinateImmersiveView(
                rpcModel: appModel.rpcModel,
                coordinateTransforms: appModel.coordinateTransforms
            ) {
                ImmersiveView()
                    .environment(appModel)
                    .environment(gameManager) // 🌟 ImmersiveViewに渡す
            }
            .onAppear {
                appModel.immersiveSpaceState = .open
            }
            .onDisappear {
                appModel.immersiveSpaceState = .closed
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
