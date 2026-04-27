import CoreGraphics
import Foundation

public struct SignatureAsset: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var pngData: Data
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, pngData: Data, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.pngData = pngData
        self.createdAt = createdAt
    }
}

public struct PlacedSignature: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var assetID: UUID
    public var pageIndex: Int
    public var bounds: CGRect

    public init(id: UUID = UUID(), assetID: UUID, pageIndex: Int, bounds: CGRect) {
        self.id = id
        self.assetID = assetID
        self.pageIndex = pageIndex
        self.bounds = bounds
    }
}
