import UIKit
import RealmSwift
import RxSwift
import HSEthereumKit

class BalanceController: UIViewController {
    let disposeBag = DisposeBag()

    @IBOutlet weak var balanceLabel: UILabel?
    @IBOutlet weak var progressLabel: UILabel?
    @IBOutlet weak var lastBlockLabel: UILabel?

    @IBOutlet weak var balanceCoinLabel: UILabel?
    @IBOutlet weak var progressCoinLabel: UILabel?
    
    private lazy var dateFormatter: DateFormatter = {
        var formatter = DateFormatter()
        formatter.timeZone = TimeZone.autoupdatingCurrent
        formatter.locale = Locale.current
        formatter.dateFormat = "MMM d, yyyy, HH:mm"
        return formatter
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Balance"

        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Logout", style: .plain, target: self, action: #selector(logout))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Refresh", style: .plain, target: self, action: #selector(refresh))

        let ethereumKit = Manager.shared.ethereumKit!

        update(balance: ethereumKit.balance)
        erc20update(balance: ethereumKit.erc20Balance(contractAddress: Manager.contractAddress))

        update(lastBlockHeight: ethereumKit.lastBlockHeight)
        update(kitState: ethereumKit.kitState)
        erc20update(kitState: ethereumKit.kitState)

        Manager.shared.balanceSubject.observeOn(MainScheduler.instance).subscribe(onNext: { [weak self] balance in
                self?.update(balance: balance)
        }).disposed(by: disposeBag)

        Manager.shared.lastBlockHeight.observeOn(MainScheduler.instance).subscribe(onNext: { [weak self] height in
                self?.update(lastBlockHeight: height)
        }).disposed(by: disposeBag)

        Manager.shared.progressSubject.observeOn(MainScheduler.instance).subscribe(onNext: { [weak self] progress in
            self?.update(kitState: progress)
        }).disposed(by: disposeBag)

        Manager.shared.erc20Adapter.balanceSubject.observeOn(MainScheduler.instance).subscribe(onNext: { [weak self] balance in
            self?.erc20update(balance: balance)
        }).disposed(by: disposeBag)

        Manager.shared.erc20Adapter.progressSubject.observeOn(MainScheduler.instance).subscribe(onNext: { [weak self] kitState in
            self?.erc20update(kitState: kitState)
        }).disposed(by: disposeBag)

        ethereumKit.start()
    }

    @objc func logout() {
        Manager.shared.logout()

        if let window = UIApplication.shared.keyWindow {
            UIView.transition(with: window, duration: 0.5, options: .transitionCrossDissolve, animations: {
                window.rootViewController = UINavigationController(rootViewController: WordsController())
            })
        }
    }

    @objc func refresh() {
        Manager.shared.ethereumKit.refresh()
    }

    @IBAction func showRealmInfo() {
        print(Manager.shared.ethereumKit.debugInfo)
    }

    private func update(balance: Decimal) {
        balanceLabel?.text = "Balance: \(balance)"
    }

    private func erc20update(balance: Decimal) {
        balanceCoinLabel?.text = "Balance Coin: \(balance)"
    }

    private func update(kitState: EthereumKit.KitState) {
        let kitStateString: String

        switch kitState {
        case .synced: kitStateString = "Synced!"
        case .syncing: kitStateString = "Syncing"
        case .notSynced: kitStateString = "Not Synced"
        }

        progressLabel?.text = "Sync State: \(kitStateString)"
    }

    private func erc20update(kitState: EthereumKit.KitState) {
        let kitStateString: String

        switch kitState {
        case .synced: kitStateString = "Synced!"
        case .syncing: kitStateString = "Syncing"
        case .notSynced: kitStateString = "Not Synced"
        }

        progressCoinLabel?.text = "Sync State: \(kitStateString)"
    }

    private func update(lastBlockHeight: Int?) {
        if let lastBlockHeight = lastBlockHeight {
            lastBlockLabel?.text = "Last Block: \(Int(lastBlockHeight))"
        } else {
            lastBlockLabel?.text = "Last Block: n/a"
        }
    }

}
