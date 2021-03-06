import Foundation
import RealmSwift
import RxSwift
import HSCryptoKit
import HSHDWalletKit

public class EthereumKit {
    private static let refreshInterval: TimeInterval = 60.0

    private static let ethDecimal = 18
    private static let ethGasLimit = 21000
    private static let erc20GasLimit = 100000
    private static let ethRate: Decimal = pow(10, ethDecimal)

    private let disposeBag = DisposeBag()

    public weak var delegate: EthereumKitDelegate?

    private let wallet: Wallet

    private let realmFactory: RealmFactory
    private let addressValidator: AddressValidator
    private let geth: Geth
    private let gethProvider: IGethProviderProtocol

    private let reachabilityManager: ReachabilityManager

    private let refreshTimer: IPeriodicTimer
    private let refreshManager: RefreshManager

    private var balanceNotificationToken: NotificationToken?
    private var transactionsNotificationToken: NotificationToken?

    private var erc20Holders = [String: Erc20Holder]()

    public var receiveAddress: String
    public var balance: Decimal = 0

    public var lastBlockHeight: Int? = nil
    public var kitState: KitState = .notSynced {
        didSet {
            delegate?.kitStateUpdated(state: kitState)
        }
    }

    public init(withWords words: [String], networkType: NetworkType, walletId: String, infuraKey: String, etherscanKey: String, debugPrints: Bool = false) {
        realmFactory = RealmFactory(realmFileName: "\(walletId)-\(networkType.rawValue).realm")
        addressValidator = AddressValidator()

        let network: Network

        switch networkType {
        case .mainNet:
            network = .mainnet
        case .testNet:
            network = .ropsten
        }

        do {
            wallet = try Wallet(seed: Mnemonic.seed(mnemonic: words), network: network, debugPrints: debugPrints)
        } catch {
            fatalError("Can't create hdWallet")
        }

        receiveAddress = wallet.address()
        let configuration = Configuration(
                network: network,
                nodeEndpoint: network.infura + infuraKey,
                etherscanAPIKey: etherscanKey,
                debugPrints: debugPrints
        )
        geth = Geth(configuration: configuration)
        gethProvider = GethProvider(geth: geth)

        reachabilityManager = ReachabilityManager()

        refreshTimer = PeriodicTimer(interval: EthereumKit.refreshInterval)
        refreshManager = RefreshManager(reachabilityManager: reachabilityManager, timer: refreshTimer)

        if let balanceString = realmFactory.realm.objects(EthereumBalance.self).filter("address = %@", wallet.address()).first?.value,
           let balanceDecimal = Decimal(string: balanceString) {
            balance = balanceDecimal / EthereumKit.ethRate
        }
        lastBlockHeight = realmFactory.realm.objects(EthereumBlockHeight.self).first?.blockHeight

        balanceNotificationToken = balanceResults.observe { [weak self] changeset in
            self?.handleBalance(changeset: changeset)
        }

        transactionsNotificationToken = transactionRealmResults.observe { [weak self] changeset in
            self?.handleTransactions(changeset: changeset)
        }

        refreshManager.delegate = self
    }

    public var debugInfo: String {
        var lines = [String]()

        lines.append("PUBLIC KEY: \(wallet.publicKey()) ADDRESS: \(wallet.address())")
        lines.append("TRANSACTION COUNT: \(transactionRealmResults.count)")

        return lines.joined(separator: "\n")
    }

    public func register(token: Erc20KitDelegate) {
        guard erc20Holders[token.contractAddress] == nil else {
            return
        }
        let holder = Erc20Holder(delegate: token)
        erc20Holders[token.contractAddress] = holder
        realmFactory.realm.objects(EthereumBalance.self).filter("address = %@", token.contractAddress).forEach { ethereumBalance in
            update(ethereumBalance: ethereumBalance)
        }

        refresh()
    }

    public func unregister(contractAddress: String) {
        erc20Holders.removeValue(forKey: contractAddress)
    }

    private func update(ethereumBalance: EthereumBalance) {
        if let balanceWei = Decimal(string: ethereumBalance.value) {
            let balanceDecimal = balanceWei / pow(10, ethereumBalance.decimal)
            if ethereumBalance.address == receiveAddress {
                balance = balanceDecimal
            }

            erc20Holders[ethereumBalance.address]?.balance = balanceDecimal
        }
    }


    // Manage Kit methods
    public func start() {
        refresh()
    }

    public func clear() throws {
        erc20Holders.forEach { contractAddress, _ in unregister(contractAddress: contractAddress) }

        let realm = realmFactory.realm

        refreshTimer.invalidate()
        try realm.write {
            realm.deleteAll()
        }
    }

    private func changeAllStates(state: KitState) {
        kitState = state
        erc20Holders.values.forEach { $0.kitState = state }
    }

    public func refresh() {
        guard reachabilityManager.isReachable else {
            changeAllStates(state: .notSynced)
            return
        }
        guard kitState != .syncing else {
            return
        }
        for holder in erc20Holders.values {
            if holder.kitState == .syncing {
                return
            }
        }
        let ethAddress = receiveAddress

        changeAllStates(state: .syncing)

        refreshManager.didRefresh()

        Single.zip(
                        gethProvider.getBlockNumber(),
                        gethProvider.getGasPrice(),
                        gethProvider.getBalance(address: ethAddress, contractAddress: nil, blockParameter: .latest)
                )
                .subscribeOn(ConcurrentDispatchQueueScheduler(qos: .background))
                .observeOn(MainScheduler.instance)
                .subscribe(onSuccess: { [weak self] lastBlockHeight, gasPrice, ethBalance in
                    self?.update(lastBlockHeight: lastBlockHeight)
                    self?.update(gasPrice: gasPrice)
                    self?.update(balance: ethBalance, address: ethAddress, decimal: EthereumKit.ethDecimal)

                    self?.refreshTransactions()
                }, onError: { [weak self] _ in
                    self?.changeAllStates(state: .notSynced)
                })
                .disposed(by: disposeBag)
    }

    public func validate(address: String) throws {
        try addressValidator.validate(address: address)
    }

    public func transactions(fromHash: String? = nil, limit: Int? = nil) -> Single<[EthereumTransaction]> {
        return transactions(fromHash: fromHash, limit: limit, query: "contractAddress = '' AND invalidTx = false")
    }

    private func transactions(fromHash: String?, limit: Int?, query: String) -> Single<[EthereumTransaction]> {
        return Single.create { observer in
            let realm = self.realmFactory.realm
            var transactions = realm.objects(EthereumTransaction.self).filter(query).sorted(byKeyPath: "timestamp", ascending: false)

            if let fromHash = fromHash, let fromTransaction = transactions.filter("txHash = %@", fromHash).first {
                transactions = transactions.filter("timestamp < %@", fromTransaction.timestamp)
            }

            let results: [EthereumTransaction]
            if let limit = limit {
                results = Array(transactions.prefix(limit))
            } else {
                results = Array(transactions)
            }

            observer(.success(results))
            return Disposables.create()
        }
    }

    public var fee: Decimal {
        // only for standart transactions without data
        let gasPrice = (Decimal(ethereumGasPrice.gasPrice) * Decimal(EthereumKit.ethGasLimit)) / EthereumKit.ethRate
        return gasPrice
    }

    // Send transaction methods
    public func send(to address: String, value: Decimal, gasPrice: Int? = nil, completion: ((Error?) -> ())? = nil) {
        geth.getTransactionCount(of: wallet.address(), blockParameter: .pending) { result in
            switch result {
            case .success(let nonce):
                self.send(nonce: nonce, address: address, value: value, gasPrice: gasPrice ?? self.ethereumGasPrice.gasPrice, completion: completion)
            case .failure(let error):
                completion?(error)
            }
        }
    }

    private func send(nonce: Int, address: String, value: Decimal, gasPrice: Int, completion: ((Error?) -> ())? = nil) {
        let selfAddress = wallet.address()

        // check value
        guard let weiString: String = convert(value: value, completion: completion)?.asString(withBase: 10) else {
            return
        }

        // make raw transaction
        let rawTransaction: RawTransaction

        let gas = Int(EthereumKit.ethGasLimit)
        rawTransaction = RawTransaction(wei: weiString, to: address, gasPrice: gasPrice, gasLimit: gas, nonce: nonce)
        do {
            let tx = try self.wallet.sign(rawTransaction: rawTransaction)

            // It returns the transaction ID.
            geth.sendRawTransaction(rawTransaction: tx) { [weak self] result in
                switch result {
                case .success(let sentTransaction):
                    let transaction = EthereumTransaction(txHash: sentTransaction.id, from: selfAddress, to: address, gas: gas, gasPrice: gasPrice, value: weiString, timestamp: Int(Date().timeIntervalSince1970))
                    self?.addSentTransaction(transaction: transaction)
                    completion?(nil)
                case .failure(let error):
                    completion?(error)
                }
            }
        } catch {
            completion?(error)
        }
    }

    // Database objects
    private var ethereumGasPrice: EthereumGasPrice {
        let realm = realmFactory.realm
        guard let ethereumGasPrice = realm.objects(EthereumGasPrice.self).first else {
            let gasPrice = EthereumGasPrice()
            try? realm.write {
                realm.add(gasPrice, update: true)
            }
            return gasPrice
        }
        return ethereumGasPrice
    }

    private var transactionRealmResults: Results<EthereumTransaction> {
        return realmFactory.realm.objects(EthereumTransaction.self).sorted(byKeyPath: "timestamp", ascending: false)
    }

    private var balanceResults: Results<EthereumBalance> {
        return realmFactory.realm.objects(EthereumBalance.self).sorted(byKeyPath: "value", ascending: false)
    }

    // Database Update methods
    private func update(balance: Balance, address: String, decimal: Int) {
        let realm = realmFactory.realm

        let ethereumBalance = EthereumBalance(address: address, decimal: decimal, balance: balance)
        try? realm.write {
            realm.add(ethereumBalance, update: true)
        }
        update(ethereumBalance: ethereumBalance)
    }

    private func refreshTransactions() {
        let realm = realmFactory.realm
        let lastBlockHeight = realm.objects(EthereumTransaction.self).sorted(byKeyPath: "blockNumber", ascending: false).first?.blockNumber ?? 0

        gethProvider.getTransactions(address: receiveAddress, erc20: false, startBlock: Int64(lastBlockHeight + 1))
                .subscribeOn(ConcurrentDispatchQueueScheduler(qos: .background))
                .observeOn(MainScheduler.instance)
                .subscribe(onSuccess: { [weak self] transactions in
                    self?.save(transactions: transactions)
                    self?.kitState = .synced
                }, onError: { [weak self] _ in
                    self?.kitState = .notSynced
                })
                .disposed(by: disposeBag)

        guard !erc20Holders.isEmpty else {
            return
        }

        let erc20LastBlockHeight = realm.objects(EthereumTransaction.self).filter("contractAddress != ''").sorted(byKeyPath: "blockNumber", ascending: false).first?.blockNumber ?? 0
        gethProvider.getTransactions(address: receiveAddress, erc20: true, startBlock: Int64(erc20LastBlockHeight + 1))
                .subscribeOn(ConcurrentDispatchQueueScheduler(qos: .background))
                .observeOn(MainScheduler.instance)
                .subscribe(onSuccess: { [weak self] transactions in
                    self?.save(transactions: transactions)
                    self?.refreshErc20Balances()
                }, onError: { [weak self] _ in
                    self?.erc20Holders.values.forEach { $0.kitState = .notSynced }
                })
                .disposed(by: disposeBag)
    }

    private func refreshErc20Balances() {
        erc20Holders.values.forEach { holder in
            let erc20Address = holder.delegate.contractAddress

            gethProvider.getBalance(address: receiveAddress, contractAddress: erc20Address, blockParameter: .latest)
                    .subscribeOn(ConcurrentDispatchQueueScheduler(qos: .background))
                    .observeOn(MainScheduler.instance)
                    .subscribe(onSuccess: { [weak self] balance in
                        self?.update(balance: balance, address: erc20Address, decimal: holder.delegate.decimal)
                        holder.kitState = .synced
                    }, onError: { _ in
                        holder.kitState = .notSynced
                    })
                    .disposed(by: disposeBag)
        }
    }

    private func save(transactions: Transactions) {
        let realm = realmFactory.realm
        try? realm.write {
            transactions.elements.map({ EthereumTransaction(transaction: $0) }).forEach {
                realm.add($0, update: true)
            }
        }
    }

    private func update(lastBlockHeight: Int) {
        let realm = realmFactory.realm

        let ethereumBlockHeight = EthereumBlockHeight(blockHeight: lastBlockHeight)
        try? realm.write {
            realm.add(ethereumBlockHeight, update: true)
        }

        self.lastBlockHeight = lastBlockHeight
        delegate?.lastBlockHeightUpdated(height: lastBlockHeight)
        erc20Holders.forEach { _, holder in holder.delegate.lastBlockHeightUpdated(height: lastBlockHeight) }
    }

    private func update(gasPrice wei: Wei) {
        guard let gasPrice = wei.toInt() else {
            // print("too big value")
            return
        }

        let ethereumGasPrice = EthereumGasPrice(gasPrice: gasPrice)

        let realm = realmFactory.realm
        try? realm.write {
            realm.add(ethereumGasPrice, update: true)
        }
    }


    private func convert(value: Decimal, completion: ((Error?) -> ())? = nil) -> BInt? {
        do {
            return try Converter.toWei(ether: value)
        } catch {
            completion?(error)
            return nil
        }
    }

    private func addSentTransaction(transaction: EthereumTransaction) {
        let realm = realmFactory.realm
        guard realm.objects(EthereumTransaction.self).filter("primary = %@", transaction.primary).first == nil else {
            // no need to save
            return
        }
        try? realm.write {
            realm.add(transaction, update: true)
        }
    }

    // Handlers
    private func handleTransactions(changeset: RealmCollectionChange<Results<EthereumTransaction>>) {
        if case let .update(collection, deletions, insertions, modifications) = changeset {

            let insertions = insertions.map { collection[$0] }.filter { !$0.invalidTx }
            let modifications = modifications.map { collection[$0] }.filter { !$0.invalidTx }

            let ethereumInsertions = insertions.filter { $0.contractAddress.isEmpty }
            let ethereumModifications = modifications.filter { $0.contractAddress.isEmpty }
            if !ethereumInsertions.isEmpty || !ethereumModifications.isEmpty {
                delegate?.transactionsUpdated(
                        inserted: ethereumInsertions,
                        updated: ethereumModifications,
                        deleted: deletions
                )
            }
            erc20Holders.forEach { address, holder in
                let erc20Insertions = insertions.filter { $0.contractAddress == address }
                let erc20Modifications = modifications.filter { $0.contractAddress == address }
                if !erc20Insertions.isEmpty || !erc20Modifications.isEmpty {
                    holder.delegate.transactionsUpdated(
                            inserted: erc20Insertions,
                            updated: erc20Modifications,
                            deleted: deletions
                    )
                }
            }
        }
    }

    private func handleBalance(changeset: RealmCollectionChange<Results<EthereumBalance>>) {
        if case let .update(collection, _, insertions, modifications) = changeset {
            let union: [EthereumBalance] = (insertions.map { collection[$0] }) + modifications.map { collection[$0] }
            union.forEach { balance in
                if let balanceWei = Decimal(string: balance.value) {
                    let balanceDecimal = balanceWei / pow(10, balance.decimal)
                    if balance.address == receiveAddress {
                        delegate?.balanceUpdated(balance: balanceDecimal)
                    } else {
                        erc20Holders[balance.address]?.delegate.balanceUpdated(balance: balanceDecimal)
                    }
                }
            }
        }
    }

}

// ERC20 Extension
public extension EthereumKit {
    public var erc20Fee: Decimal {
        // only for erc20 coin maximum fee
        return (Decimal(ethereumGasPrice.gasPrice) * Decimal(EthereumKit.erc20GasLimit)) / EthereumKit.ethRate
    }

    public func erc20Balance(contractAddress: String) -> Decimal {
        return erc20Holders[contractAddress]?.balance ?? 0
    }

    public func erc20Transactions(contractAddress: String, fromHash: String? = nil, limit: Int? = nil) -> Single<[EthereumTransaction]> {
        return transactions(fromHash: fromHash, limit: limit, query: "contractAddress = '\(contractAddress)'")
    }

    private func erc20BalanceResults(contractAddress: String) -> Results<EthereumBalance> {
        return realmFactory.realm.objects(EthereumBalance.self).filter("address = %@", contractAddress).sorted(byKeyPath: "value", ascending: false)
    }

    public func erc20Send(to address: String, contractAddress: String, value: Decimal, gasPrice: Int? = nil, completion: ((Error?) -> ())? = nil) {
        guard let decimal = erc20Holders[contractAddress]?.delegate.decimal else {
            completion?(EthereumKitError.contractError(.contractNotExist(contractAddress)))
            return
        }
        let contract = ERC20(contractAddress: contractAddress, decimal: decimal)
        let gasPrice = gasPrice ?? ethereumGasPrice.gasPrice
        geth.getTransactionCount(of: wallet.address(), blockParameter: .pending) { result in
            switch result {
            case .success(let nonce):
                self.erc20Send(nonce: nonce, address: address, contract: contract, value: value, gasPrice: gasPrice, completion: completion)
            case .failure(let error):
                completion?(error)
            }
        }
    }

    private func parameterData(address: String, amount: String, contract: ERC20, completion: ((Error?) -> ())? = nil) -> Data? {
        do {
            return try contract.generateDataParameter(toAddress: address, amount: amount)
        } catch {
            completion?(error)
            return nil
        }
    }

    private func erc20Send(nonce: Int, address: String, contract: ERC20, value: Decimal, gasPrice: Int, completion: ((Error?) -> ())? = nil) {
        let selfAddress = wallet.address()

        // check value
        guard let bIntValue = try? contract.power(amount: String(describing: value)) else {
            completion?(EthereumKitError.convertError(.failedToConvert(value)))
            return
        }
        // make raw transaction
        let rawTransaction: RawTransaction
        let gasLimit = EthereumKit.erc20GasLimit

        // check right contract parameters create
        let params = ERC20.ContractFunctions.transfer(address: address, amount: bIntValue).data
        rawTransaction = RawTransaction(wei: "0", to: contract.contractAddress, gasPrice: gasPrice, gasLimit: gasLimit, nonce: nonce, data: params)
        do {
            let tx = try self.wallet.sign(rawTransaction: rawTransaction)

            // It returns the transaction ID.
            geth.sendRawTransaction(rawTransaction: tx) { [weak self] result in
                switch result {
                case .success(let sentTransaction):
                    let transaction = EthereumTransaction(txHash: sentTransaction.id, from: selfAddress, to: address, contractAddress: contract.contractAddress, gas: gasLimit, gasPrice: gasPrice, value: bIntValue.asString(withBase: 10), timestamp: Int(Date().timeIntervalSince1970), input: params.toHexString().addHexPrefix())
                    self?.addSentTransaction(transaction: transaction)
                    completion?(nil)
                case .failure(let error):
                    completion?(error)
                }
            }
        } catch {
            completion?(error)
        }
    }

}

public protocol EthereumKitDelegate: class {
    func transactionsUpdated(inserted: [EthereumTransaction], updated: [EthereumTransaction], deleted: [Int])
    func balanceUpdated(balance: Decimal)
    func lastBlockHeightUpdated(height: Int)
    func kitStateUpdated(state: EthereumKit.KitState)
}

public protocol Erc20KitDelegate: EthereumKitDelegate {
    var contractAddress: String { get }
    var decimal: Int { get }
}

extension EthereumKit {

    public enum NetworkType {
        case mainNet
        case testNet

        var rawValue: String {
            return "eth-\(self)"
        }
    }

    public enum KitState {
        case synced
        case syncing
        case notSynced
    }

}

extension EthereumKit: IRefreshKitDelegate {

    func onRefresh() {
        refresh()
    }

    func onDisconnect() {
        changeAllStates(state: .notSynced)
    }

}
