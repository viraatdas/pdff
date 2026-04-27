import Combine
import Foundation

@MainActor
public final class SignatureStore: ObservableObject {
    @Published public private(set) var signatures: [SignatureAsset] = []

    private let account = "signatures"

    public init() {
        do {
            signatures = try KeychainJSONStore.load([SignatureAsset].self, account: account) ?? []
        } catch {
            signatures = []
        }
    }

    public func add(_ signature: SignatureAsset) {
        signatures.append(signature)
        persist()
    }

    public func delete(_ signature: SignatureAsset) {
        signatures.removeAll { $0.id == signature.id }
        persist()
    }

    public func signature(id: UUID) -> SignatureAsset? {
        signatures.first { $0.id == id }
    }

    private func persist() {
        try? KeychainJSONStore.save(signatures, account: account)
    }
}
