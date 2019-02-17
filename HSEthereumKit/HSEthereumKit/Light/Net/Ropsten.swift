import Foundation

class Ropsten: INetwork {

    let id = 3
    let genesisBlockHash = Data(hex: "41941023680923e0fe4d74a34bdac8141f2540e3ae90623718e47d66d1ca4a2d")

    let checkpointBlock = BlockHeader(
            hashHex: Data(hex: "b718dab7255a9a6221f34cc3bfdee6b427a6ee113a9b493c2137fafee06bd8e3"),
            totalDifficulty: Data(hex: String(18080483061023450, radix: 16)),
            parentHash: Data(hex: "0477f92045e2e769dd38b75bca093df0a481cca8edf43215adb74b4c261c77c7"),
            unclesHash: Data(hex: "1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347"),
            coinbase: Data(hex: "0aaf1317b31289ecb455a090c6c16613f652058c"),
            stateRoot: Data(hex: "db0bc97f465344bebfbf3691b60ecbf329011713628049dfc9a36fb9e47a02c5"),
            transactionsRoot: Data(hex: "87b695dda523578f4c6d1e78b0a374ad7202777abb00f2cb06379eaa34d67848"),
            receiptsRoot: Data(hex: "c3c47ce2544b8e37512bf12f0502347c5bc97c52f3e3c2522aa8a33f822c8967"),
            logsBloom: Data(hex: "00000000000200000000000000000000000000000000000000000000000000000000000010000000000000000020000000000000000000000020000000200000000002000000100000000000000000000004000000000000000020000001000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004000000000000000000000020000000000000000000020000000000000000000020000200000000000000000000000000000000000002000000000000000000000000000000000000100000010000000000000000000000000000010000000000000000000000000000000"),
            difficulty: Data(hex: "847e0b90"),
            height: BInt(4890000),
            gasLimit: Data(hex: "7a1200"),
            gasUsed: 1272524,
            timestamp: 1548376375,
            extraData: Data(hex: "d883010815846765746888676f312e31312e34856c696e7578"),
            mixHash: Data(hex: "44d36166661e2ca01a4f1797447acdeae0627c8b5d1b06d4a3b08a6495acf468"),
            nonce: Data(hex: "775342c80a5e43fa")
    )

}