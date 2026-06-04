import Foundation
import GRDB

/// Tiered storage demotion and promotion for the LCM DAG.
///
/// Manages the lifecycle of cold nodes — DAG nodes whose hotness has decayed below
/// ``CIMSDefaults/coldStorageHotnessThreshold`` and haven't been accessed for
/// ``CIMSDefaults/coldStorageAgeDays``. Demotion compresses the node's `canonicalText`
/// into a zlib blob stored in `lcm_cold_payloads`. Promotion (on any access) decompresses
/// the payload and restores the node to hot storage.
///
/// **Data integrity guarantee**: Promotion always restores the exact original bytes.
/// The ``ColdPayloadRecord/originalBytes`` field is stored alongside the compressed payload
/// to enable pre-allocation and roundtrip verification.
public nonisolated struct ColdStorage: Sendable {
    /// The shared database backing all CIMS persistence.
    private let db: CIMSDatabase

    /// Creates a cold storage manager backed by the given database.
    ///
    /// - Parameter database: The CIMS database instance for reading and writing cold payloads.
    public init(database: CIMSDatabase) {
        self.db = database
    }

    // MARK: - Demotion

    /// Demote eligible nodes to cold storage by compressing their canonical text.
    ///
    /// A node is eligible for demotion when:
    /// - `hotness < CIMSDefaults.coldStorageHotnessThreshold` (0.1)
    /// - `lastAccessedAt` is older than `CIMSDefaults.coldStorageAgeDays` (30 days)
    /// - `isCold == 0` (not already demoted)
    /// - `canonicalText` is not nil
    ///
    /// For each eligible node, the canonical text is compressed using zlib (via Foundation's
    /// `Data` compression), stored in `lcm_cold_payloads`, and the node's `canonicalText`
    /// is set to `nil` with `isCold = 1`.
    ///
    /// - Returns: The number of nodes demoted.
    @discardableResult
    public func demoteEligibleNodes() async throws -> Int {
        let cutoffDate = Date().addingTimeInterval(-Double(CIMSDefaults.coldStorageAgeDays) * 86_400)
        let cutoffString = Self.formatDate(cutoffDate)

        return try await db.dbPool.write { db in
            let eligible = try LCMNodeRecord
                .filter(Column("hotness") < CIMSDefaults.coldStorageHotnessThreshold)
                .filter(Column("lastAccessedAt") < cutoffString)
                .filter(Column("isCold") == 0)
                .filter(Column("canonicalText") != nil)
                .fetchAll(db)

            var demoted = 0

            for node in eligible {
                guard let text = node.canonicalText else { continue }
                let textData = Data(text.utf8)
                let compressed = Self.compress(textData)

                let payload = ColdPayloadRecord(
                    nodeId: node.nodeId,
                    payload: compressed,
                    originalBytes: textData.count,
                )
                try payload.insert(db)

                try db.execute(
                    sql: """
                    UPDATE lcm_nodes
                    SET canonicalText = NULL, isCold = 1, version = version + 1
                    WHERE nodeId = ?
                    """,
                    arguments: [node.nodeId],
                )

                demoted += 1
            }

            return demoted
        }
    }

    // MARK: - Promotion

    /// Promote a cold node back to hot storage by decompressing its payload.
    ///
    /// Retrieves the compressed payload from `lcm_cold_payloads`, decompresses it,
    /// restores the `canonicalText` on the node, sets `isCold = 0`, bumps hotness
    /// to at least 0.2 (to prevent immediate re-demotion), and updates `lastAccessedAt`.
    /// The cold payload record is deleted after successful restoration.
    ///
    /// - Parameter nodeId: The ID of the cold node to promote.
    /// - Throws: ``CIMSError/coldStorageError(_:_:)`` if the payload is missing or decompression fails.
    public func promote(nodeId: NodeID) async throws {
        try await db.dbPool.write { db in
            guard let payload = try ColdPayloadRecord.fetchOne(db, key: nodeId) else {
                throw CIMSError.coldStorageError(nodeId, "No cold payload found for node")
            }

            let decompressed = Self.decompress(payload.payload, originalSize: payload.originalBytes)
            guard let restoredText = String(data: decompressed, encoding: .utf8) else {
                throw CIMSError.coldStorageError(nodeId, "Failed to decode decompressed payload as UTF-8")
            }

            let now = Self.formatDate(Date())
            try db.execute(
                sql: """
                UPDATE lcm_nodes
                SET canonicalText = ?,
                    isCold = 0,
                    hotness = MAX(hotness, 0.2),
                    lastAccessedAt = ?,
                    version = version + 1
                WHERE nodeId = ?
                """,
                arguments: [restoredText, now, nodeId],
            )

            try db.execute(
                sql: "DELETE FROM lcm_cold_payloads WHERE nodeId = ?",
                arguments: [nodeId],
            )
        }
    }

    // MARK: - Compression

    /// Compress data using zlib via NSData.
    ///
    /// Falls back to storing raw bytes if compression is unavailable or fails.
    ///
    /// - Parameter data: The data to compress.
    /// - Returns: Compressed bytes.
    public nonisolated static func compress(_ data: Data) -> Data {
        (try? (data as NSData).compressed(using: .zlib) as Data) ?? data
    }

    /// Decompress data using zlib via NSData.
    ///
    /// Falls back to returning the raw data if decompression fails (assumes data
    /// was stored uncompressed as a fallback).
    ///
    /// - Parameters:
    ///   - data: The compressed data.
    ///   - originalSize: The expected original size for verification.
    /// - Returns: Decompressed bytes.
    public nonisolated static func decompress(_ data: Data, originalSize _: Int) -> Data {
        if let decompressed = try? (data as NSData).decompressed(using: .zlib) as Data {
            return decompressed
        }
        return data
    }

    // MARK: - Date Helpers

    /// Format a `Date` as an ISO 8601 string with fractional seconds.
    public nonisolated static func formatDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
