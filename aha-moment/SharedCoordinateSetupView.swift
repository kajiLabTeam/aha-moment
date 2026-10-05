import ImmersiveRPCKit
import MultipeerConnectivity
import SwiftUI

/// ゲームホストが操作する、2 台用の座標共有ウィザード。
/// RPC Kit の計算・通信機構はそのまま使い、Peer ID の大小ではなくゲームホストが
/// 操作の開始者になるようにしている。
struct SharedCoordinateSetupView: View {
    let appModel: AppModel
    let game: MultiplayerGameSession

    @State private var selectedPeerID: Int?

    private var coordinateSession: CoordinateTransforms.CoordinateSession {
        appModel.coordinateTransforms.session
    }

    private var peers: [MCPeerID] {
        appModel.rpcModel.mcPeerIDUUIDWrapper.standby
    }

    private var selectedPeerName: String? {
        peers.first(where: { $0.hash == coordinateSession.otherPeerId })?.displayName
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("端末間の座標共有")
                .font(.title2)

            switch coordinateSession.state {
            case .initial, .selecting:
                initialContent
            case .getTransformMatrixHost, .getTransformMatrixClient:
                captureContent
            case .confirm:
                confirmContent
            case .prepared:
                preparedContent
            }
        }
        .frame(minHeight: 250)
    }

    @ViewBuilder
    private var initialContent: some View {
        if game.isHosting {
            if peers.isEmpty {
                Text("もう一台の Vision Pro を検索・接続中です")
                    .foregroundStyle(.secondary)
            } else {
                Text("接続する端末を選び、ゲームホストが座標合わせを開始します。")
                    .multilineTextAlignment(.center)
                Picker("参加端末", selection: $selectedPeerID) {
                    Text("選択してください").tag(nil as Int?)
                    ForEach(peers, id: \.hash) { peer in
                        Text(peer.displayName).tag(peer.hash as Int?)
                    }
                }
                Button("指合わせの準備を開始") {
                    guard let selectedPeerID else { return }
                    game.beginCoordinateSharing(with: selectedPeerID)
                }
                .disabled(selectedPeerID == nil)
            }
        } else {
            Text("ゲームホストが座標共有の準備を開始するのを待っています。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var captureContent: some View {
        Text("指合わせ (coordinateSession.matrixCount + 1) / \(coordinateSession.matrixCountLimit)")
            .font(.title3)
        Text("両方の Vision Pro で Immersive Space を開いてから、人差し指同士を触れさせます。")
            .multilineTextAlignment(.center)
        if let selectedPeerName {
            Text("接続先: \(selectedPeerName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if game.isHosting {
            if appModel.immersiveSpaceState != .open {
                Text("この端末の Immersive Space を先に開いてください")
                    .foregroundStyle(.orange)
            }
            Button("\(coordinateSession.matrixCount + 1) 回目の指合わせを開始") {
                game.captureCoordinateSample()
            }
            .disabled(appModel.immersiveSpaceState != .open || coordinateSession.requestedTransform)
        } else {
            Text(coordinateSession.requestedTransform
                 ? "指先位置を取得中です（約3秒）"
                 : "ゲームホストが取得を開始します")
                .foregroundStyle(.secondary)
        }

        if game.isHosting {
            Button("座標共有をやり直す", role: .destructive) {
                game.resetCoordinateSharing()
            }
        }
    }

    @ViewBuilder
    private var confirmContent: some View {
        Text("4点の指合わせを取得しました")
            .font(.title3)
        Text("ゲームホストが確定すると、両端末に座標変換を保存します。")
            .multilineTextAlignment(.center)
        if game.isHosting {
            Button("座標共有を確定") {
                game.finishCoordinateSharing()
            }
            Button("やり直す", role: .destructive) {
                game.resetCoordinateSharing()
            }
        } else {
            Text("ゲームホストによる確定待ちです")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var preparedContent: some View {
        Label("座標共有が完了しました", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        Text("両端末で同じ現実空間を基準に、同期したゲームを開始できます。")
            .multilineTextAlignment(.center)
        if game.isHosting {
            Button("座標共有をやり直す", role: .destructive) {
                game.resetCoordinateSharing()
            }
        }
    }
}
