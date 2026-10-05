import Foundation
import ImmersiveRPCKit
import Observation
import simd

/// ネットワークで共有するゲームの最小状態。座標やモデルデータそのものは送らず、
/// 各端末が同じローカルアセットから再生する。
enum AhaRoundPhase: String, Codable, Sendable {
    case setup
    case running
    case completed
}

struct AhaRoundSnapshot: Codable, Sendable {
    let hostPeerID: Int
    let roundID: UUID
    let targetID: String
    let phase: AhaRoundPhase
}

struct AhaPeerRequest: Codable, Sendable {
    let peerID: Int
}

struct AhaAnswerRequest: Codable, Sendable {
    let peerID: Int
    let modelID: String
}

/// ホスト座標系で確定したオブジェクト／オクルージョンボックスの配置。
/// `run(transforming:)` の送信時に、各参加端末の座標系へ変換される。
/// simd_float4x4 はこのターゲットで Codable ではないため、列優先の16 Floatへ変換する。
struct AhaTransformMatrix: Codable, Sendable {
    private let values: [Float]

    init(_ matrix: simd_float4x4) {
        values = [
            matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w,
            matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w,
            matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w,
            matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w,
        ]
    }

    var simdMatrix: simd_float4x4 {
        guard values.count == 16 else { return matrix_identity_float4x4 }
        return simd_float4x4(columns: (
            SIMD4(values[0], values[1], values[2], values[3]),
            SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]),
            SIMD4(values[12], values[13], values[14], values[15])
        ))
    }
}

struct AhaObjectPlacement: Codable, Sendable {
    let objectID: String
    let matrix: AhaTransformMatrix

    init(objectID: String, matrix: simd_float4x4) {
        self.objectID = objectID
        self.matrix = AhaTransformMatrix(matrix)
    }
}

struct AhaOcclusionBoxPlacement: Codable, Sendable {
    let id: UUID
    let matrix: AhaTransformMatrix

    init(id: UUID, matrix: simd_float4x4) {
        self.id = id
        self.matrix = AhaTransformMatrix(matrix)
    }
}

struct AhaPlacementSnapshot: Codable, Sendable {
    let objects: [AhaObjectPlacement]
    let occlusionBoxes: [AhaOcclusionBoxPlacement]
}

/// ゲーム進行の唯一の決定者。ホストだけがスナップショットを配信し、参加者は要求のみ送る。
@MainActor
@Observable
final class MultiplayerGameSession {
    private weak var gameManager: GameManager?
    private weak var rpcModel: RPCModel?

    private(set) var hostPeerID: Int?
    private(set) var latestSnapshot: AhaRoundSnapshot?
    /// ホスト空間のまま保持する正本。参加端末へ送る瞬間にだけ座標変換する。
    private var authoritativePlacement: AhaPlacementSnapshot?

    var isHosting: Bool {
        guard let rpcModel, let hostPeerID else { return false }
        return rpcModel.mcPeerIDUUIDWrapper.mine.hash == hostPeerID
    }

    /// 未接続の単独準備時またはゲームホストだけが、実空間の配置を変更できる。
    var canEditPlacement: Bool {
        hostPeerID == nil || isHosting
    }

    func attach(gameManager: GameManager, rpcModel: RPCModel) {
        self.gameManager = gameManager
        self.rpcModel = rpcModel
    }

    /// ゲームホストが選んだ相手と、両端末の ImmersiveRPCKit 座標合わせを同時に開始する。
    /// Kit 標準 UI は Peer ID の大小で開始者を決めるため、ゲーム側ではこのメソッドだけを
    /// 使い、ゲームホストが操作を一元化する。
    func beginCoordinateSharing(with peerID: Int) {
        guard isHosting, let rpcModel else { return }

        let myID = rpcModel.mcPeerIDUUIDWrapper.mine.hash
        _ = rpcModel.run(localOnly: CoordinateTransformEntity.localRequest(
            .initMyPeer(.init(peerId: myID))
        ))
        _ = rpcModel.run(remoteOnly: CoordinateTransformEntity.request(
            .initMyPeer(.init(peerId: peerID)), to: peerID
        ))

        _ = rpcModel.run(localOnly: CoordinateTransformEntity.localRequest(
            .initOtherPeer(.init(peerId: peerID))
        ))
        _ = rpcModel.run(remoteOnly: CoordinateTransformEntity.request(
            .initOtherPeer(.init(peerId: myID)), to: peerID
        ))

        let localState: CoordinateTransforms.CoordinateSession.PreparationState =
            myID > peerID ? .getTransformMatrixHost : .getTransformMatrixClient
        let remoteState: CoordinateTransforms.CoordinateSession.PreparationState =
            myID > peerID ? .getTransformMatrixClient : .getTransformMatrixHost

        _ = rpcModel.run(localOnly: CoordinateTransformEntity.localRequest(
            .setState(.init(state: localState))
        ))
        _ = rpcModel.run(remoteOnly: CoordinateTransformEntity.request(
            .setState(.init(state: remoteState)), to: peerID
        ))
    }

    /// 両端末の指先位置を同時に採取する。呼び出すのはゲームホストだけ。
    func captureCoordinateSample() {
        guard isHosting,
              let rpcModel,
              let otherPeerID = coordinateOtherPeerID
        else { return }

        // sync により自端末と相手端末の双方で requestedTransform が立ち、
        // Immersive Space 上の右人差し指を同時に 3 秒後に採取する。
        _ = rpcModel.run(sync: CoordinateTransformEntity.request(
            .requestTransform,
            to: otherPeerID
        ))
    }

    /// 4 回分の採取が終わったら、計算・行列保存・完了状態を両端末に反映する。
    func finishCoordinateSharing() {
        guard isHosting, let rpcModel, let otherPeerID = coordinateOtherPeerID else { return }

        let calculate = rpcModel.run(sync: CoordinateTransformEntity.request(
            .clacAffineMatrix,
            to: otherPeerID
        ))
        guard case .success = calculate else { return }

        _ = rpcModel.run(sync: CoordinateTransformEntity.request(
            .setAffineMatrix,
            to: otherPeerID
        ))
        _ = rpcModel.run(sync: CoordinateTransformEntity.request(
            .setState(.init(state: .prepared)),
            to: otherPeerID
        ))
        sendAuthoritativePlacement(to: .all)
    }

    func resetCoordinateSharing() {
        guard isHosting, let rpcModel else { return }
        let otherPeerID = coordinateOtherPeerID
        _ = rpcModel.run(localOnly: CoordinateTransformEntity.localRequest(.resetPeer))
        if let otherPeerID {
            _ = rpcModel.run(remoteOnly: CoordinateTransformEntity.request(
                .resetPeer,
                to: otherPeerID
            ))
        }
    }

    private var coordinateOtherPeerID: Int? {
        guard let rpcModel else { return nil }
        let session = gameCoordinateTransforms?.session
        guard session?.isOtherPeerInitialized == true else { return nil }
        let peerID = session?.otherPeerId ?? 0
        return rpcModel.mcPeerIDUUIDWrapper.standby.contains(where: { $0.hash == peerID })
            ? peerID
            : nil
    }

    private weak var gameCoordinateTransforms: CoordinateTransforms?

    func attach(coordinateTransforms: CoordinateTransforms) {
        gameCoordinateTransforms = coordinateTransforms
    }

    /// Aさんが微調整・オクルージョン配置を確定するたびに呼ぶ。
    /// 相手との指合わせ完了後なら、相手座標系へ変換して直ちに反映する。
    func updateAuthoritativePlacement(_ placement: AhaPlacementSnapshot) {
        // Aさんが単独で配置した後、ゲームホストを選ぶケースに備え、
        // 接続前でもこの端末の候補配置を保持しておく。
        authoritativePlacement = placement
        guard isHosting else { return }
        guard gameCoordinateTransforms?.session.state == .prepared else { return }
        sendAuthoritativePlacement(to: .all)
    }

    private func sendAuthoritativePlacement(to target: RPCUnicastMultiTarget) {
        guard isHosting, let rpcModel, let authoritativePlacement,
              gameCoordinateTransforms?.session.state == .prepared
        else { return }

        _ = rpcModel.run(
            transforming: target,
            AhaGameEntity.self,
            .applyPlacement(authoritativePlacement)
        )
    }

    /// この端末をゲーム進行のホストにする。複数端末で同時に押さず、1台だけで実行する。
    func becomeHost() {
        guard let gameManager, let rpcModel else { return }
        let hostID = rpcModel.mcPeerIDUUIDWrapper.mine.hash
        let targetID = gameManager.prepareMultiplayerRound()
        publish(AhaRoundSnapshot(
            hostPeerID: hostID,
            roundID: UUID(),
            targetID: targetID,
            phase: .setup
        ))
    }

    /// 既存ホストへ現在のスナップショットを要求する。
    func joinExistingHost() {
        guard let rpcModel else { return }
        let request = AhaGameEntity.request(
            .requestSnapshot(AhaPeerRequest(peerID: rpcModel.mcPeerIDUUIDWrapper.mine.hash)),
            to: 0
        )
        _ = rpcModel.run(remoteOnly: request, toEach: .all)
    }

    func requestStartRound() {
        guard let rpcModel else { return }
        if hostPeerID == nil {
            // 単独実行や最初の端末では、その端末をホストとして開始する。
            becomeHost()
        }
        if isHosting {
            startRoundAsHost()
        } else if let hostPeerID {
            _ = rpcModel.run(remoteOnly: AhaGameEntity.request(
                .requestStart(AhaPeerRequest(peerID: rpcModel.mcPeerIDUUIDWrapper.mine.hash)),
                to: hostPeerID
            ))
        }
    }

    /// ローカルの指差し結果をホストへ送り、ホストだけが正解を確定する。
    func submitAnswer(modelID: String) {
        guard let rpcModel else { return }
        if isHosting {
            completeRoundAsHost(answeredModelID: modelID)
        } else if let hostPeerID {
            _ = rpcModel.run(remoteOnly: AhaGameEntity.request(
                .submitAnswer(AhaAnswerRequest(
                    peerID: rpcModel.mcPeerIDUUIDWrapper.mine.hash,
                    modelID: modelID
                )),
                to: hostPeerID
            ))
        }
    }

    func requestReplay() {
        guard let rpcModel else { return }
        if isHosting {
            createNextRoundAsHost()
        } else if let hostPeerID {
            _ = rpcModel.run(remoteOnly: AhaGameEntity.request(
                .requestReplay(AhaPeerRequest(peerID: rpcModel.mcPeerIDUUIDWrapper.mine.hash)),
                to: hostPeerID
            ))
        }
    }

    private func startRoundAsHost() {
        guard let snapshot = latestSnapshot, snapshot.phase == .setup else { return }
        publish(AhaRoundSnapshot(
            hostPeerID: snapshot.hostPeerID,
            roundID: snapshot.roundID,
            targetID: snapshot.targetID,
            phase: .running
        ))
    }

    private func completeRoundAsHost(answeredModelID: String) {
        guard let snapshot = latestSnapshot,
              snapshot.phase == .running,
              snapshot.targetID == answeredModelID else { return }
        publish(AhaRoundSnapshot(
            hostPeerID: snapshot.hostPeerID,
            roundID: snapshot.roundID,
            targetID: snapshot.targetID,
            phase: .completed
        ))
    }

    private func createNextRoundAsHost() {
        guard let gameManager, let rpcModel else { return }
        let targetID = gameManager.prepareMultiplayerRound()
        publish(AhaRoundSnapshot(
            hostPeerID: rpcModel.mcPeerIDUUIDWrapper.mine.hash,
            roundID: UUID(),
            targetID: targetID,
            phase: .setup
        ))
    }

    private func publish(_ snapshot: AhaRoundSnapshot) {
        guard let rpcModel else { return }

        // 接続相手がまだいない状態で MCSession.send(_:toPeers:) を呼ぶと
        // "Invalid peerIDs parameter" になる。先にローカルだけを確定し、
        // 後から接続した端末には joinExistingHost() の応答で配信する。
        _ = apply(snapshot: snapshot)
        guard !rpcModel.mcPeerIDUUIDWrapper.standby.isEmpty else { return }
        _ = rpcModel.run(syncAll: AhaGameEntity.request(.applySnapshot(snapshot)))
    }

    fileprivate func apply(snapshot: AhaRoundSnapshot) -> RPCResult {
        hostPeerID = snapshot.hostPeerID
        latestSnapshot = snapshot
        gameManager?.applyMultiplayerSnapshot(snapshot)
        return .success(())
    }

    fileprivate func respondToSnapshotRequest(_ request: AhaPeerRequest) -> RPCResult {
        guard isHosting, let rpcModel, let latestSnapshot else { return .success(()) }
        let result = rpcModel.run(remoteOnly: AhaGameEntity.request(
            .deliverSnapshot(latestSnapshot),
            to: request.peerID
        ))
        // 既に座標共有済みの再参加者なら、配置も同時に復元する。
        sendAuthoritativePlacement(to: .peer(request.peerID))
        return result
    }

    fileprivate func handleStartRequest(_ request: AhaPeerRequest) -> RPCResult {
        guard isHosting else { return .success(()) }
        startRoundAsHost()
        return .success(())
    }

    fileprivate func handleAnswerRequest(_ request: AhaAnswerRequest) -> RPCResult {
        guard isHosting else { return .success(()) }
        completeRoundAsHost(answeredModelID: request.modelID)
        return .success(())
    }

    fileprivate func handleReplayRequest(_ request: AhaPeerRequest) -> RPCResult {
        guard isHosting else { return .success(()) }
        createNextRoundAsHost()
        return .success(())
    }

    fileprivate func applyPlacement(_ placement: AhaPlacementSnapshot) -> RPCResult {
        // transforming は送信元でもローカル実行される。ホストの正本は上書きしない。
        guard !isHosting else { return .success(()) }
        gameManager?.applySharedPlacement(placement)
        return .success(())
    }
}

/// ImmersiveRPCKitへ登録する、アハ体験専用の型安全なRPC定義。
@available(visionOS 26.0, *)
struct AhaGameEntity: RPCEntity {
    static let codingKey = "ahaGameEntity"

    enum BroadcastMethod: RPCBroadcastMethod {
        typealias Handler = MultiplayerGameSession
        case applySnapshot(AhaRoundSnapshot)

        func execute(on handler: MultiplayerGameSession) -> RPCResult {
            switch self {
            case .applySnapshot(let snapshot):
                return handler.apply(snapshot: snapshot)
            }
        }
    }
    //TransformalUnicastMethodを実装して　アフィン行列を適用すれば実装できるかも
    enum UnicastMethod: RPCTransformableUnicastMethod {
        typealias Handler = MultiplayerGameSession
        case requestSnapshot(AhaPeerRequest)
        case deliverSnapshot(AhaRoundSnapshot)
        case requestStart(AhaPeerRequest)
        case submitAnswer(AhaAnswerRequest)
        case requestReplay(AhaPeerRequest)
        case applyPlacement(AhaPlacementSnapshot)

        func execute(on handler: MultiplayerGameSession) -> RPCResult {
            switch self {
            case .requestSnapshot(let request):
                return handler.respondToSnapshotRequest(request)
            case .deliverSnapshot(let snapshot):
                return handler.apply(snapshot: snapshot)
            case .requestStart(let request):
                return handler.handleStartRequest(request)
            case .submitAnswer(let request):
                return handler.handleAnswerRequest(request)
            case .requestReplay(let request):
                return handler.handleReplayRequest(request)
            case .applyPlacement(let placement):
                return handler.applyPlacement(placement)
            }
        }

        /// ホスト空間の行列を、送信先ごとのARワールド座標へ変換する。
        func applying(affineMatrix: simd_float4x4) -> Self {
            switch self {
            case .applyPlacement(let placement):
                let objects = placement.objects.map {
                    AhaObjectPlacement(
                        objectID: $0.objectID,
                        matrix: affineMatrix * $0.matrix.simdMatrix
                    )
                }
                let boxes = placement.occlusionBoxes.map {
                    AhaOcclusionBoxPlacement(
                        id: $0.id,
                        matrix: affineMatrix * $0.matrix.simdMatrix
                    )
                }
                return .applyPlacement(.init(objects: objects, occlusionBoxes: boxes))
            default:
                return self
            }
        }
    }
}
