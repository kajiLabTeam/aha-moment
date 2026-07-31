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
    var body: some View {
        
        VStack {
            TransformationMatrixPreparationView(
                rpcModel: appModel.rpcModel,
                coordinateTransforms: appModel.coordinateTransforms
            )
            Model3D(named: "Scene", bundle: realityKitContentBundle)
                .padding(.bottom, 50)
            
            Text("Hello, world!")
            
            ToggleImmersiveSpaceButton()
        }
        .padding()
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
