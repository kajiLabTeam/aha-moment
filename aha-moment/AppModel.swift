//
//  AppModel.swift
//  aha-moment
//
//  Created by k24052kk on 2026/07/31.
//

import SwiftUI
import ImmersiveRPCKit

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    let coordinateTransforms = CoordinateTransforms()
    // 通信の送受信バッファ
    private let sendWrapper    = ExchangeDataWrapper()
    private let receiveWrapper = ExchangeDataWrapper()
    // Peer ID 管理
    private let peerWrapper    = MCPeerIDUUIDWrapper()
    
    // MultipeerConnectivity セッション管理
    private let peerManager: PeerManager
    
    
    
    // RPC モデル
    let rpcModel: RPCModel
    init() {
        peerManager = PeerManager(
            sendExchangeDataWrapper: sendWrapper,
            receiveExchangeDataWrapper: receiveWrapper,
            mcPeerIDUUIDWrapper: peerWrapper,
            serviceType: "aha-moment"  // Info.plist の NSBonjourServices に登録した値と一致させる
        )
        rpcModel = RPCModel(
            sendExchangeDataWrapper: sendWrapper,
            receiveExchangeDataWrapper: receiveWrapper,
            mcPeerIDUUIDWrapper: peerWrapper,
            entities: [
                RPCEntityRegistration<CoordinateTransformEntity>(handler: coordinateTransforms)
                
            ]
        )
    }
    let immersiveSpaceID = "ImmersiveSpace"
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.closed
}
