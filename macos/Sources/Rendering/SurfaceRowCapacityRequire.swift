import Foundation

extension SurfaceRowCapacityLedger {
    /// Record that `rows` rows must exist and `row` needs `vertexCount`
    /// vertices. Only ever raises: a smaller requirement from a later
    /// callback must not shrink one the provisioner still owes. Caller holds
    /// the surface lock.
    func require(rows: Int, row: Int, vertexCount: Int) {
        requiredRows = max(requiredRows, rows)
        requiredVertexCounts[row] = max(requiredVertexCounts[row], vertexCount)
    }

    /// Put back a provisioning pass's requirement after it failed, merged
    /// with whatever was recorded while it ran. Caller holds the surface lock.
    func require(rows: Int, vertexCounts: [Int]) {
        requiredRows = max(requiredRows, rows)
        for row in 0..<rows {
            requiredVertexCounts[row] = max(requiredVertexCounts[row], vertexCounts[row])
        }
    }
}
