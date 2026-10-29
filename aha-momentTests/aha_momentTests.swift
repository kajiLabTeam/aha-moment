//
//  aha_momentTests.swift
//  aha-momentTests
//
//  Created by k24052kk on 2026/07/31.
//

import Testing
@testable import aha_moment
import Foundation
import simd

@MainActor
struct aha_momentTests {

    @Test func targetsCycleInModelDefinitionOrder() {
        let gameManager = GameManager()

        #expect(gameManager.prepareMultiplayerRound() == "obj1")
        #expect(gameManager.prepareMultiplayerRound() == "obj2")
        #expect(gameManager.prepareMultiplayerRound() == "obj3")
        #expect(gameManager.prepareMultiplayerRound() == "obj1")
    }

    /// 通信で送る16要素の列優先表現が、位置・回転・拡大率を失わず復元できることを確認する。
    @Test func placementSnapshotCodableRoundTripPreservesFullTransforms() throws {
        let objectTransform = makeTransform(
            translation: SIMD3(1.25, -0.5, 3.75),
            yRotation: .pi / 3,
            scale: SIMD3(0.4, 1.5, 2.0)
        )
        let boxTransform = makeTransform(
            translation: SIMD3(-2.0, 0.8, 0.25),
            yRotation: -.pi / 4,
            scale: SIMD3(repeating: 1)
        )
        let markerTransform = makeTransform(
            translation: SIMD3(0.5, 1.1, -0.4),
            yRotation: .pi / 8,
            scale: SIMD3(repeating: 1)
        )
        let boxID = UUID()
        let snapshot = AhaPlacementSnapshot(
            objects: [.init(objectID: "obj1", matrix: objectTransform)],
            occlusionBoxes: [.init(id: boxID, matrix: boxTransform)],
            coordinateValidationMarker: markerTransform
        )

        let decoded = try JSONDecoder().decode(
            AhaPlacementSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        #expect(decoded.objects.map(\.objectID) == ["obj1"])
        #expect(decoded.occlusionBoxes.map(\.id) == [boxID])
        expectEqual(decoded.objects[0].matrix.simdMatrix, objectTransform)
        expectEqual(decoded.occlusionBoxes[0].matrix.simdMatrix, boxTransform)
        expectEqual(decoded.coordinateValidationMarker!.simdMatrix, markerTransform)
    }

    /// affineMatrixProvider が返した「送信元→送信先」行列を、配置行列の左から掛ける契約を確認する。
    @Test func placementTransformIsPreMultipliedForReceivingCoordinateSpace() {
        let hostObjectTransform = makeTransform(
            translation: SIMD3(1, 2, 3),
            yRotation: .pi / 6,
            scale: SIMD3(0.5, 1, 2)
        )
        let hostBoxTransform = makeTransform(
            translation: SIMD3(-1, 0, 2),
            yRotation: -.pi / 3,
            scale: SIMD3(repeating: 1)
        )
        let hostToParticipant = makeTransform(
            translation: SIMD3(10, -2, 4),
            yRotation: .pi / 2,
            scale: SIMD3(repeating: 1)
        )
        let hostMarkerTransform = makeTransform(
            translation: SIMD3(0.3, 0.2, -0.1),
            yRotation: .pi / 5,
            scale: SIMD3(repeating: 1)
        )
        let boxID = UUID()
        let placement = AhaPlacementSnapshot(
            objects: [.init(objectID: "obj1", matrix: hostObjectTransform)],
            occlusionBoxes: [.init(id: boxID, matrix: hostBoxTransform)],
            coordinateValidationMarker: hostMarkerTransform
        )

        let transformedMethod = AhaGameEntity.UnicastMethod
            .applyPlacement(placement)
            .applying(affineMatrix: hostToParticipant)

        guard case .applyPlacement(let participantPlacement) = transformedMethod else {
            Issue.record("applyPlacement が変換後も applyPlacement ではありません")
            return
        }

        #expect(participantPlacement.objects[0].objectID == "obj1")
        #expect(participantPlacement.occlusionBoxes[0].id == boxID)
        expectEqual(
            participantPlacement.objects[0].matrix.simdMatrix,
            hostToParticipant * hostObjectTransform
        )
        expectEqual(
            participantPlacement.occlusionBoxes[0].matrix.simdMatrix,
            hostToParticipant * hostBoxTransform
        )
        expectEqual(
            participantPlacement.coordinateValidationMarker!.simdMatrix,
            hostToParticipant * hostMarkerTransform
        )
    }

    private func makeTransform(
        translation: SIMD3<Float>,
        yRotation: Float,
        scale: SIMD3<Float>
    ) -> simd_float4x4 {
        let translationMatrix = simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0), SIMD4(translation, 1)
        ))
        let rotationMatrix = simd_float4x4(
            simd_quatf(angle: yRotation, axis: SIMD3(0, 1, 0))
        )
        let scaleMatrix = simd_float4x4(columns: (
            SIMD4(scale.x, 0, 0, 0), SIMD4(0, scale.y, 0, 0),
            SIMD4(0, 0, scale.z, 0), SIMD4(0, 0, 0, 1)
        ))
        return translationMatrix * rotationMatrix * scaleMatrix
    }

    private func expectEqual(
        _ actual: simd_float4x4,
        _ expected: simd_float4x4,
        accuracy: Float = 0.0001
    ) {
        for column in 0..<4 {
            for row in 0..<4 {
                #expect(abs(actual[column][row] - expected[column][row]) < accuracy)
            }
        }
    }

}
