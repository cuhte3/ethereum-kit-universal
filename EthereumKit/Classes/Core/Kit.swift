import RxSwift
import HdWalletKit
import BigInt
import OpenSslKit
import Secp256k1Kit
import HsToolKit

public class Kit {
    public static let defaultGasLimit = 21_000

    private let maxGasLimit = 1_000_000
    private let defaultMinAmount: BigUInt = 1

    private let lastBlockBloomFilterSubject = PublishSubject<BloomFilter>()
    private let lastBlockHeightSubject = PublishSubject<Int>()
    private let syncStateSubject = PublishSubject<SyncState>()
    private let accountStateSubject = PublishSubject<AccountState>()

    private let blockchain: IBlockchain
    private let transactionManager: TransactionManager
    private let transactionSyncManager: TransactionSyncManager
    private let transactionBuilder: TransactionBuilder
    private let transactionSigner: TransactionSigner
    private let state: EthereumKitState

    public let address: Address

    public let networkType: NetworkType
    public let uniqueId: String
    public let etherscanService: EtherscanService

    public let logger: Logger


    init(blockchain: IBlockchain, transactionManager: TransactionManager, transactionSyncManager: TransactionSyncManager, transactionBuilder: TransactionBuilder, transactionSigner: TransactionSigner, state: EthereumKitState = EthereumKitState(), address: Address, networkType: NetworkType, uniqueId: String, etherscanService: EtherscanService, logger: Logger) {
        self.blockchain = blockchain
        self.transactionManager = transactionManager
        self.transactionSyncManager = transactionSyncManager
        self.transactionBuilder = transactionBuilder
        self.transactionSigner = transactionSigner
        self.state = state
        self.address = address
        self.networkType = networkType
        self.uniqueId = uniqueId
        self.etherscanService = etherscanService
        self.logger = logger

        state.accountState = blockchain.accountState
        state.lastBlockHeight = blockchain.lastBlockHeight
    }

}

// Public API Extension

extension Kit {

    public var lastBlockHeight: Int? {
        state.lastBlockHeight
    }

    public var accountState: AccountState? {
        state.accountState
    }

    public var syncState: SyncState {
        blockchain.syncState
    }

    public var transactionsSyncState: SyncState {
        transactionSyncManager.state
    }

    public var receiveAddress: Address {
        address
    }

    public var lastBlockHeightObservable: Observable<Int> {
        lastBlockHeightSubject.asObservable()
    }

    public var lastBlockBloomFilterObservable: Observable<BloomFilter> {
        lastBlockBloomFilterSubject.asObservable()
    }

    public var syncStateObservable: Observable<SyncState> {
        syncStateSubject.asObservable()
    }

    public var transactionsSyncStateObservable: Observable<SyncState> {
        transactionSyncManager.stateObservable
    }

    public var accountStateObservable: Observable<AccountState> {
        accountStateSubject.asObservable()
    }

    public var etherTransactionsObservable: Observable<[FullTransaction]> {
        transactionManager.etherTransactionsObservable
    }

    public var allTransactionsObservable: Observable<[FullTransaction]> {
        transactionManager.allTransactionsObservable
    }

    public func start() {
        blockchain.start()
    }

    public func stop() {
        blockchain.stop()
    }

    public func refresh() {
        blockchain.refresh()
    }

    public func etherTransactionsSingle(fromHash: Data? = nil, limit: Int? = nil) -> Single<[FullTransaction]> {
        transactionManager.etherTransactionsSingle(fromHash: fromHash, limit: limit)
    }

    public func transaction(hash: Data) -> FullTransaction? {
        transactionManager.transaction(hash: hash)
    }

    public func fullTransactions(fromSyncOrder: Int?) -> [FullTransaction] {
        transactionManager.transactions(fromSyncOrder: fromSyncOrder)
    }

    public func fullTransactions(byHashes hashes: [Data]) -> [FullTransaction] {
        transactionManager.transactions(byHashes: hashes)
    }

    public func sendSingle(address: Address, value: BigUInt, transactionInput: Data = Data(), gasPrice: Int, gasLimit: Int, nonce: Int? = nil) -> Single<FullTransaction> {
        var syncNonceSingle = blockchain.nonceSingle(defaultBlockParameter: .pending)

        if let nonce = nonce {
            syncNonceSingle = Single<Int>.just(nonce)
        }

        return syncNonceSingle.flatMap { [weak self] nonce in
            guard let kit = self else {
                return Single<FullTransaction>.error(SendError.nonceNotAvailable)
            }

            let rawTransaction = kit.transactionBuilder.rawTransaction(gasPrice: gasPrice, gasLimit: gasLimit, to: address, value: value, data: transactionInput, nonce: nonce)

            return kit.blockchain.sendSingle(rawTransaction: rawTransaction)
                    .do(onSuccess: { [weak self] transaction in
                        self?.transactionManager.handle(sentTransaction: transaction)
                    })
                    .map {
                        FullTransaction(transaction: $0)
                    }
        }
    }

    public func sendSingle(transactionData: TransactionData, gasPrice: Int, gasLimit: Int, nonce: Int? = nil) -> Single<FullTransaction> {
        sendSingle(address: transactionData.to, value: transactionData.value, transactionInput: transactionData.input, gasPrice: gasPrice, gasLimit: gasLimit, nonce: nonce)
    }

    public func signedTransaction(address: Address, value: BigUInt, transactionInput: Data = Data(), gasPrice: Int, gasLimit: Int, nonce: Int) throws -> Data {
        let rawTransaction = transactionBuilder.rawTransaction(gasPrice: gasPrice, gasLimit: gasLimit, to: address, value: value, data: transactionInput, nonce: nonce)
        let signature = try transactionSigner.signature(rawTransaction: rawTransaction)
        return transactionBuilder.encode(rawTransaction: rawTransaction, signature: signature)
    }

    public var debugInfo: String {
        var lines = [String]()

        lines.append("ADDRESS: \(address.hex)")

        return lines.joined(separator: "\n")
    }

    public func getStorageAt(contractAddress: Address, positionData: Data, defaultBlockParameter: DefaultBlockParameter = .latest) -> Single<Data> {
        blockchain.getStorageAt(contractAddress: contractAddress, positionData: positionData, defaultBlockParameter: defaultBlockParameter)
    }

    public func call(contractAddress: Address, data: Data, defaultBlockParameter: DefaultBlockParameter = .latest) -> Single<Data> {
        blockchain.call(contractAddress: contractAddress, data: data, defaultBlockParameter: defaultBlockParameter)
    }

    public func estimateGas(to: Address?, amount: BigUInt, gasPrice: Int?) -> Single<Int> {
        // without address - provide default gas limit
        guard let to = to else {
            return Single.just(Kit.defaultGasLimit)
        }

        // if amount is 0 - set default minimum amount
        let resolvedAmount: BigUInt = amount == 0 ? defaultMinAmount : amount

        return blockchain.estimateGas(to: to, amount: resolvedAmount, gasLimit: maxGasLimit, gasPrice: gasPrice, data: nil)
    }

    public func estimateGas(to: Address?, amount: BigUInt?, gasPrice: Int?, data: Data?) -> Single<Int> {
        blockchain.estimateGas(to: to, amount: amount, gasLimit: maxGasLimit, gasPrice: gasPrice, data: data)
    }

    public func estimateGas(transactionData: TransactionData, gasPrice: Int?) -> Single<Int> {
        estimateGas(to: transactionData.to, amount: transactionData.value, gasPrice: gasPrice, data: transactionData.input)
    }

    public func add(syncer: ITransactionSyncer) {
        transactionSyncManager.add(syncer: syncer)
    }
    
    public func removeSyncer(byId id: String) {
        transactionSyncManager.removeSyncer(byId: id)
    }

    public func statusInfo() -> [(String, Any)] {
        [
            ("Last Block Height", "\(state.lastBlockHeight.map { "\($0)" } ?? "N/A")"),
            ("Sync State", blockchain.syncState.description),
            ("Blockchain Source", blockchain.source),
            ("Transactions Source", "Infura.io, Etherscan.io")
        ]
    }

}


extension Kit: IBlockchainDelegate {

    func onUpdate(lastBlockBloomFilter: BloomFilter) {
        lastBlockBloomFilterSubject.onNext(lastBlockBloomFilter)
    }

    func onUpdate(lastBlockHeight: Int) {
        guard state.lastBlockHeight != lastBlockHeight else {
            return
        }

        state.lastBlockHeight = lastBlockHeight

        lastBlockHeightSubject.onNext(lastBlockHeight)
    }

    func onUpdate(accountState: AccountState) {
        guard state.accountState != accountState else {
            return
        }

        state.accountState = accountState
        accountStateSubject.onNext(accountState)
    }

    func onUpdate(syncState: SyncState) {
        syncStateSubject.onNext(syncState)
    }

}

extension Kit {

    public static func bscInstance(words: [String], syncSource: SyncSource, bscscanApiKey: String, walletId: String, minLogLevel: Logger.Level = .error) throws -> Kit {
        try instance(
                words: words,
                networkType: NetworkType.bscMainNet,
                syncSource: syncSource, etherscanApiKey: bscscanApiKey, walletId: walletId,minLogLevel: minLogLevel
        )
    }

    public static func ethInstance(words: [String], networkType: NetworkType = .ethMainNet, syncSource: SyncSource, etherscanApiKey: String, walletId: String, minLogLevel: Logger.Level = .error) throws -> Kit {
        try instance(
                words: words,
                networkType: networkType,
                syncSource: syncSource, etherscanApiKey: etherscanApiKey, walletId: walletId, minLogLevel: minLogLevel
        )
    }

    public static func address(words: [String], networkType: NetworkType = .ethMainNet) throws -> Address {
        let wallet = hdWallet(words: words, networkType: networkType)
        let privateKey = try wallet.privateKey(account: 0, index: 0, chain: .external)

        return ethereumAddress(privateKey: privateKey)
    }

    public static func clear(exceptFor excludedFiles: [String]) throws {
        let fileManager = FileManager.default
        let fileUrls = try fileManager.contentsOfDirectory(at: dataDirectoryUrl(), includingPropertiesForKeys: nil)

        for filename in fileUrls {
            if !excludedFiles.contains(where: { filename.lastPathComponent.contains($0) }) {
                try fileManager.removeItem(at: filename)
            }
        }
    }

    private static func infuraDomain(networkType: NetworkType) -> String {
        switch networkType {
        case .ropsten: return "ropsten.infura.io"
        case .kovan: return "kovan.infura.io"
        case .ethMainNet: return "mainnet.infura.io"
        case .bscMainNet: return "bsc-dataseed.binance.org"
        }
    }

    private static func rpcSyncer(syncSource: SyncSource, networkType: NetworkType, networkManager: NetworkManager, address: Address, logger: Logger) -> IRpcSyncer {
        let syncer: IRpcSyncer
        let reachabilityManager = ReachabilityManager()

        switch syncSource {
        case let .infuraWebSocket(id, secret):
            if case .bscMainNet = networkType {
                let socket = InfuraWebSocket(url: URL(string: "wss://bsc-ws-node.nariox.org:443")!, projectSecret: secret, reachabilityManager: reachabilityManager, logger: logger)
                syncer = WebSocketRpcSyncer.instance(address: address, socket: socket, logger: logger)
            } else {
                let url = URL(string: "wss://\(infuraDomain(networkType: networkType))/ws/v3/\(id)")!
                let socket = InfuraWebSocket(url: url, projectSecret: secret, reachabilityManager: reachabilityManager, logger: logger)
                syncer = WebSocketRpcSyncer.instance(address: address, socket: socket, logger: logger)
            }

        case let .infura(id, secret):
            let apiProvider = InfuraApiProvider(networkManager: networkManager, domain: infuraDomain(networkType: networkType), id: id, secret: secret)
            syncer = ApiRpcSyncer(address: address, rpcApiProvider: apiProvider, reachabilityManager: reachabilityManager)
        }

        return syncer
    }

    private static func instance(words: [String], networkType: NetworkType, syncSource: SyncSource, etherscanApiKey: String, walletId: String, minLogLevel: Logger.Level = .error) throws -> Kit {
        let logger = Logger(minLogLevel: minLogLevel)
        let uniqueId = "\(walletId)-\(networkType)"

        let wallet = hdWallet(words: words, networkType: networkType)
        let privateKey = try wallet.privateKey(account: 0, index: 0, chain: .external)
        let address = ethereumAddress(privateKey: privateKey)

        let network = networkType.network
        let networkManager = NetworkManager(logger: logger)
        let syncer = rpcSyncer(syncSource: syncSource, networkType: networkType, networkManager: networkManager, address: address, logger: logger)


        let transactionSigner = TransactionSigner(network: network, privateKey: privateKey.raw)
        let transactionBuilder = TransactionBuilder(address: address)
        let etherscanService = EtherscanService(networkManager: networkManager, network: network, etherscanApiKey: etherscanApiKey, address: address)

        let storage: IApiStorage = try ApiStorage(databaseDirectoryUrl: dataDirectoryUrl(), databaseFileName: "api-\(uniqueId)")
        let blockchain = RpcBlockchain.instance(address: address, storage: storage, syncer: syncer, transactionSigner: transactionSigner, transactionBuilder: transactionBuilder, logger: logger)

        let transactionsProvider = EtherscanTransactionProvider(service: etherscanService)
        let transactionStorage: ITransactionStorage & ITransactionSyncerStateStorage = TransactionStorage(databaseDirectoryUrl: try dataDirectoryUrl(), databaseFileName: "transactions-\(uniqueId)")
        let notSyncedTransactionPool = NotSyncedTransactionPool(storage: transactionStorage)
        let notSyncedTransactionManager = NotSyncedTransactionManager(pool: notSyncedTransactionPool, storage: transactionStorage)

        let internalTransactionSyncer = InternalTransactionSyncer(provider: transactionsProvider, storage: transactionStorage)
        let ethereumTransactionSyncer = EthereumTransactionSyncer(provider: transactionsProvider)
        let transactionSyncer = TransactionSyncer(blockchain: blockchain, storage: transactionStorage)
        let pendingTransactionSyncer = PendingTransactionSyncer(blockchain: blockchain, storage: transactionStorage)
        let transactionSyncManager = TransactionSyncManager(notSyncedTransactionManager: notSyncedTransactionManager)
        let transactionManager = TransactionManager(address: address, storage: transactionStorage, transactionSyncManager: transactionSyncManager)

        transactionSyncManager.add(syncer: ethereumTransactionSyncer)
        transactionSyncManager.add(syncer: internalTransactionSyncer)
        transactionSyncManager.add(syncer: transactionSyncer)
        transactionSyncManager.add(syncer: pendingTransactionSyncer)

        let kit = Kit(blockchain: blockchain, transactionManager: transactionManager, transactionSyncManager: transactionSyncManager, transactionBuilder: transactionBuilder, transactionSigner: transactionSigner, address: address, networkType: networkType, uniqueId: uniqueId, etherscanService: etherscanService, logger: logger)

        blockchain.delegate = kit
        transactionSyncManager.set(ethereumKit: kit)
        transactionSyncer.listener = transactionSyncManager
        pendingTransactionSyncer.listener = transactionSyncManager
        internalTransactionSyncer.listener = transactionSyncManager

        return kit
    }

    private static func dataDirectoryUrl() throws -> URL {
        let fileManager = FileManager.default

        let url = try fileManager
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("ethereum-kit", isDirectory: true)

        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)

        return url
    }

    private static func hdWallet(words: [String], networkType: NetworkType) -> HDWallet {
        let coinType: UInt32

        switch networkType {
        case .ethMainNet, .bscMainNet: coinType = 60
        default: coinType = 1
        }

        return HDWallet(seed: Mnemonic.seed(mnemonic: words), coinType: coinType, xPrivKey: 0, xPubKey: 0)
    }

    private static func ethereumAddress(privateKey: HDPrivateKey) -> Address {
        let publicKey = Data(Secp256k1Kit.Kit.createPublicKey(fromPrivateKeyData: privateKey.raw, compressed: false).dropFirst())

        return Address(raw: Data(CryptoUtils.shared.sha3(publicKey).suffix(20)))
    }

}

extension Kit {

    public enum SyncError: Error {
        case notStarted
        case noNetworkConnection
    }

    public enum SendError: Error {
        case nonceNotAvailable
        case noAccountState
    }

    public enum EstimatedLimitError: Error {
        case insufficientBalance

        var causes: [String] {
            [
                "execution reverted",
                "insufficient funds for transfer",
                "gas required exceeds"
            ]
        }
    }

}
