import Foundation

public nonisolated enum CorePassiveScreenFailure: Error, Equatable, Sendable {
    case unsupported, retired, wrongStream, outOfOrder, missingInitialGrid, gridTooLarge, invalidPacket
}

/// Ordered render instructions for a strictly passive terminal replica. No
/// snapshot-complete/readiness/empty-editor/authorization claim is made by DATA.
public nonisolated enum CorePassiveScreenUpdate: Equatable, Sendable {
    case resize(columns: UInt16, rows: UInt16)
    case data(Data)
    case closed
}

/// Requires end-to-end negotiated observer resize support. Feed the returned
/// update into a bounded renderer before acknowledging its DATA packet. Discard
/// renderer-generated input/responses: an observer must not type, resize, focus,
/// scroll the program or send queries. Retire on EOF/connection loss; a new
/// connection always gets a fresh sequence and renderer.
public nonisolated struct CorePassiveScreenSequence: Sendable {
    public static let maximumDimension = 2048
    public static let maximumCells = 262_144
    private let stream: CoreStreamID
    private var ordinal: UInt64 = 0
    public private(set) var isRetired = false
    public private(set) var columns: UInt16?
    public private(set) var rows: UInt16?

    public init(stream: CoreStream) throws {
        guard stream.observesOnly, stream.resizeNotifications else { throw CorePassiveScreenFailure.unsupported }
        self.stream = stream.id
    }

    public mutating func consume(_ packet: CoreStreamPacket) throws -> CorePassiveScreenUpdate {
        guard !isRetired else { throw CorePassiveScreenFailure.retired }
        do {
            guard packet.stream == stream, packet.frame.channel == stream.channel else { throw CorePassiveScreenFailure.wrongStream }
            guard ordinal < UInt64.max, packet.ordinal == ordinal + 1 else { throw CorePassiveScreenFailure.outOfOrder }
            let update: CorePassiveScreenUpdate
            switch packet.frame.kind {
            case .resize:
                guard packet.receipt == nil, packet.frame.payload.count == 4 else { throw CorePassiveScreenFailure.invalidPacket }
                let bytes = Array(packet.frame.payload)
                let cols = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
                let rows = UInt16(bytes[2]) | UInt16(bytes[3]) << 8
                guard cols > 0, rows > 0 else { throw CorePassiveScreenFailure.invalidPacket }
                guard Int(cols) <= Self.maximumDimension, Int(rows) <= Self.maximumDimension,
                      Int(cols) * Int(rows) <= Self.maximumCells else { throw CorePassiveScreenFailure.gridTooLarge }
                self.columns = cols; self.rows = rows
                update = .resize(columns: cols, rows: rows)
            case .data:
                guard columns != nil, rows != nil else { throw CorePassiveScreenFailure.missingInitialGrid }
                guard let receipt = packet.receipt, receipt.stream == stream, receipt.bytes == packet.frame.payload.count else {
                    throw CorePassiveScreenFailure.invalidPacket
                }
                update = .data(packet.frame.payload)
            case .close:
                guard packet.receipt == nil else { throw CorePassiveScreenFailure.invalidPacket }
                retire(); update = .closed
            default: throw CorePassiveScreenFailure.invalidPacket
            }
            ordinal = packet.ordinal
            return update
        } catch {
            retire()
            throw error
        }
    }

    public mutating func retire() {
        isRetired = true; columns = nil; rows = nil
    }
}
