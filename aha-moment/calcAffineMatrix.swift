//
//  CalcAffineMatrix.swift
//  aha-moment
//

import Accelerate
import simd

// MARK: - 🌟 不足していた拡張機能 (SIMD+.swift相当) を追加

extension Array where Element == [Double] {
    var transpose4x4: [[Double]] {
        guard self.count == 4, self[0].count == 4 else { return self }
        var result = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        for i in 0..<4 {
            for j in 0..<4 {
                result[i][j] = self[j][i]
            }
        }
        return result
    }
}

extension simd_float4x4 {
    var floatList: [[Float]] {
        return [
            [columns.0.x, columns.1.x, columns.2.x, columns.3.x],
            [columns.0.y, columns.1.y, columns.2.y, columns.3.y],
            [columns.0.z, columns.1.z, columns.2.z, columns.3.z],
            [columns.0.w, columns.1.w, columns.2.w, columns.3.w]
        ]
    }
}

// MARK: - simd_double4x4 行優先ヘルパー

extension simd_double4x4 {
    fileprivate init(rowMajor rows: [[Double]]) {
        self.init(
            columns: (
                SIMD4<Double>(rows[0][0], rows[1][0], rows[2][0], rows[3][0]),
                SIMD4<Double>(rows[0][1], rows[1][1], rows[2][1], rows[3][1]),
                SIMD4<Double>(rows[0][2], rows[1][2], rows[2][2], rows[3][2]),
                SIMD4<Double>(rows[0][3], rows[1][3], rows[2][3], rows[3][3])
            ))
    }

    fileprivate var rowMajor: [[Double]] {
        (0..<4).map { row in
            [columns.0[row], columns.1[row], columns.2[row], columns.3[row]]
        }
    }
}

/// 汎用 NxM 行列積
func matmul(_ A: [[Double]], _ B: [[Double]]) -> [[Double]] {
    let rowsA = A.count
    let colsA = A[0].count
    let colsB = B[0].count

    var result = Array(repeating: Array(repeating: 0.0, count: colsB), count: rowsA)
    for i in 0..<rowsA {
        for j in 0..<colsB {
            for k in 0..<colsA {
                result[i][j] += A[i][k] * B[k][j]
            }
        }
    }
    return result
}

/// 4x4 行列積
func matrixMul4x4(_ A: [[Double]], _ B: [[Double]]) -> [[Double]] {
    (simd_double4x4(rowMajor: A) * simd_double4x4(rowMajor: B)).rowMajor
}

func LU(_ A: [[Double]]) -> ([[Double]], [[Double]]) {
    var L = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
    var U = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)

    for i in 0..<4 {
        L[i][i] = 1

        for j in i..<4 {
            var sum: Double = 0.0
            for k in 0..<i {
                sum += L[i][k] * U[k][j]
            }
            U[i][j] = A[i][j] - sum
        }

        for j in (i + 1)..<4 {
            var sum: Double = 0.0
            for k in 0..<i {
                sum += L[j][k] * U[k][i]
            }
            L[j][i] = (A[j][i] - sum) / (U[i][i])
        }
    }

    return (L, U)
}

func eqSolve(_ A: [[Double]], _ Q: [[Double]]) -> [[Double]] {
    var (L, U) = LU(A)
    var Y = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
    var X = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)

    // 前進代入
    for i in 0..<4 {
        var dot = [Double](repeating: 0, count: 4)
        for j in 0..<i {
            for k in 0..<4 {
                dot[k] += L[i][j] * Y[j][k]
            }
        }
        for k in 0..<4 {
            Y[i][k] = Q[i][k] - dot[k]
        }
    }

    // 後退代入
    for i in stride(from: 3, through: 0, by: -1) {
        if abs(U[i][i]) < 1e-8 {
            U[i][i] = 1e-8
        }
        var dot: [Double] = [0, 0, 0, 0]
        for j in stride(from: 3, through: i + 1, by: -1) {
            for k in 0..<4 {
                dot[k] += U[i][j] * X[j][k]
            }
        }
        for k in 0..<4 {
            X[i][k] = (Y[i][k] - dot[k]) / U[i][i]
        }
    }

    return X
}

// 🌟 SVDやPolar分解など、visionOSで警告が出る未使用関数群は削除しました

func matmul4x4_4x1(_ A: [[Double]], _ B: [Double]) -> [Double] {
    var result = [Double](repeating: 0, count: 4)
    for i in 0..<4 {
        for j in 0..<3 {
            result[i] += A[i][j] * B[j]
        }
        result[i] += A[i][3]
    }
    return result
}

func matmul4x4_4x1(_ A: [[Float]], _ B: [Float]) -> [Float] {
    var result = [Float](repeating: 0, count: 4)
    for i in 0..<4 {
        for j in 0..<3 {
            result[i] += A[i][j] * B[j]
        }
        result[i] += A[i][3]
    }
    return result
}

func matmul4x4_4x1(_ A: simd_float4x4, _ B: SIMD4<Float>) -> SIMD3<Float> {
    let Am: [[Float]] = A.floatList
    let Bm: [Float] = [B.x, B.y, B.z, 1.0]
    let result = matmul4x4_4x1(Am, Bm)
    return SIMD3<Float>(result[0], result[1], result[2])
}

func calcAffineMatrix(_ A: [[[Double]]], _ B: [[[Double]]]) -> [[Double]] {
    let n = A.count

    var P: [[Double]] = []
    for i in (0..<n) {
        var rowP: [Double] = []
        for j in (0..<3) {
            rowP.append(A[i][j][3])
        }
        rowP.append(1.0)
        P.append(rowP)
    }
    if P.count == 3 {
        P.append([0, 0, 0, 0])
    }

    var Q: [[Double]] = []
    for i in (0..<n) {
        var rowQ: [Double] = []
        for j in (0..<3) {
            rowQ.append(B[i][j][3])
        }
        rowQ.append(0.0)
        Q.append(rowQ)
    }
    if Q.count == 3 {
        Q.append([0, 0, 0, 0])
    }

    let eqSolveMatrix: [[Double]] = matrixMul4x4(eqSolve(matrixMul4x4(P.transpose4x4, P), P.transpose4x4), Q)
    var affineMatrix: [[Double]] = eqSolveMatrix.transpose4x4
    affineMatrix[3][3] = 1.0
    print("アフィン変換行列の計算に成功しました")

    return affineMatrix
}
