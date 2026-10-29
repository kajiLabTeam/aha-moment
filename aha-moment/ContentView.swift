//
//  ContentView.swift
//  aha-moment
//
//  Created by k24052kk on 2026/07/31.
//

import SwiftUI
import RealityKit
import RealityKitContent

struct ContentView: View {
    @Environment(GameManager.self) private var gameManager

    var body: some View {
        VStack(spacing: 20) {
            Text("配置方式")
                .font(.title)

            HStack(spacing: 12) {
                ForEach(PlacementMode.allCases) { mode in
                    Button {
                        gameManager.setPlacementMode(mode)
                    } label: {
                        Text(mode.title)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 64)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(gameManager.placementMode == mode ? .blue : .gray)
                }
            }

            Text(gameManager.placementMode == .calibrated
                 ? "4つの基準点を取得して、研究室座標を実空間に合わせます。"
                 : "基準点を取得せず、研究室座標をVision Proアプリ内の座標としてそのまま配置します。")
                .multilineTextAlignment(.center)

            ToggleImmersiveSpaceButton()
        }
        .padding()
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
