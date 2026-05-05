# ERC-451

A semi-fungible token standard that fixes every critical issue in ERC-404 (Pandora Labs).

ERC-451 merges ERC-20 liquidity with ERC-721 NFT ownership. Every ERC-20 whole unit corresponds to one ERC-721 token — buying and selling fractions automatically mints and burns NFTs. The design is identical to ERC-404 at the surface, but the implementation is rebuilt from scratch to be safe, gas-efficient, and standards-compliant.

---

## What was wrong with ERC-404

ERC-404 shipped with six critical bugs:

| ID | Problem | Impact |
|---|---|---|
| CRIT-01 | Per-token function call loop on transfers | Block gas limit hit at ~100 tokens; ~10× over-spend on any multi-token transfer |
| CRIT-02 | Two SSTOREs per NFT ownership update | ~2,900–5,000 wasted gas per NFT transferred |
| CRIT-03 | No reentrancy guard on `safeTransferFrom` | Re-entrant drain via malicious `onERC721Received` callback |
| CRIT-04 | `erc721TotalSupply()` never decreases | Stale supply figure — burned tokens still counted |
| CRIT-05 | `supportsInterface` returns false for IERC721 | Invisible to OpenSea, Blur, and every standards-compliant marketplace |
| CRIT-06 | Exemption toggle processes all NFTs in one tx | Block gas limit hit for DEX LP pools with large NFT balances |

---

## What ERC-451 fixes

**Gas (CRIT-01, CRIT-02, GAS-01–08)**

- `_batchTransferFromOwned` moves all NFTs in a single loop, taking from the tail so no swap-and-pop is needed for remaining elements.
- `_setOwnerAndIndex` encodes owner address + owned-array index in one `uint256` and writes both in a single `SSTORE` using assembly `or`.
- `uint32[]` owned arrays pack 8 offsets per storage slot vs 1 `uint256` per slot in ERC-404 — 8× cheaper ownership array reads.
- Post-transfer balances are derived arithmetically (`senderAfter = senderBefore - value`) rather than re-reading storage.
- Dedicated `_mintERC20` path skips the cold SLOAD of `balanceOf[address(0)]` present in ERC-404's generic routing.

Estimated savings vs ERC-404:

| Operation | ERC-404 | ERC-451 | Saving |
|---|---|---|---|
| Transfer 1 whole token | ~110,000–140,000 gas | ~45,000–65,000 gas | ~55–60% |
| Transfer 10 whole tokens | ~900,000–1,200,000 gas | ~70,000–100,000 gas | ~92–95% |
| Set exemption (100 NFT address) | ~5,000,000+ (often reverts) | ~60,000 gas (paginated) | >98% |

**Security (CRIT-03)**

`safeTransferFrom` carries a `nonReentrant` storage lock (`uint8 _reentrancyLock`) that covers the full call including the `onERC721Received` callback. Checks-Effects-Interactions ordering is enforced throughout.

**Supply reporting (CRIT-04)**

- `erebusCirculatingSupply()` — true live count: `minted - bankLength`
- `erebusHighestMintedId()` — monotonic counter retained for off-chain indexers that need it

**Marketplace compatibility (CRIT-05)**

`supportsInterface` returns `true` for `IERC721` (`0x80ac58cd`) and `IERC721Metadata` (`0x5b5e139f`).

**Paginated exemption (CRIT-06)**

`_setEREBUSExempt(address, bool, batchSize)` — processes at most `batchSize` NFTs per call. Reverts with `ExemptionStillPending(target, remaining)` if more batches are needed.

**Standards compliance**

- `InsufficientAllowance` error with full context (replaces silent arithmetic underflow)
- `permit()` rejects `owner == address(0)` before nonce increment
- EIP-4906 `MetadataUpdate` event emitted when a banked token ID is recycled
- All custom errors carry relevant parameters for debuggability

---

## Trading gate

ERC-451 includes a built-in launch safety mechanism via the `tradingEnabled` flag.

```solidity
bool public tradingEnabled;
```

- Defaults to `false` at deploy time.
- While `false`, any transfer where **both** `from` and `to` are non-exempt reverts with `"Trading not enabled"`.
- `address(0)` is always exempt — initial mints are never blocked.
- The deployer, router, and liquidity pair can all be exempted before trading opens, allowing liquidity to be seeded safely.

The inheriting contract is responsible for exposing an `enableTrading()` function (owner-gated, one-way):

```solidity
function enableTrading() external onlyOwner {
    require(!tradingEnabled, "Already enabled");
    tradingEnabled = true;
    emit TradingEnabled(block.timestamp);
}
```

This pattern ensures a safe Uniswap V3 launch sequence:

1. Deploy — owner, SwapRouter02, UniversalRouter, NonfungiblePositionManager, and mint recipient are all auto-exempted.
2. The deployer mints the full supply to an exempt address — no NFTs minted.
3. **Before adding LP:** compute the V3 pool address and exempt it via `setupLiquidityPair`. This must happen first — if the pool receives tokens before being exempted, the contract tries to mint NFTs into it.
4. Add liquidity via the V3 NonfungiblePositionManager — both sides (owner and pool) are now exempt, so no NFT mechanics are triggered.
5. `enableTrading()` is called — from this point all transfers are open.

---

## Installation

```bash
npm install
```

Dependencies: `hardhat`, `@nomicfoundation/hardhat-toolbox`, `@openzeppelin/contracts ^5.x`

Requires Node.js 18+. Solidity `^0.8.24` with `evmVersion: "cancun"` (required for OpenZeppelin v5's `mcopy` opcode).

---

## Usage

### Inherit ERC451 in your contract

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC451} from "./contracts/ERC451.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract MyToken is ERC451, Ownable {
    uint256 public constant MAX_SUPPLY = 10_000;

    event TradingEnabled(uint256 timestamp);

    constructor(address router_, address owner_, address mintRecipient_)
        ERC451("MyToken", "MTK", 18)
        Ownable(owner_)
    {
        _setEREBUSExempt(router_,         true, 0);
        _setEREBUSExempt(owner_,          true, 0);
        _setEREBUSExempt(mintRecipient_,  true, 0);
    }

    function initialMint(address to_) external onlyOwner {
        _mintERC20(to_, MAX_SUPPLY * units);
    }

    function setupLiquidityPair(address pair_) external onlyOwner {
        _setEREBUSExempt(pair_, true, 0);
    }

    function enableTrading() external onlyOwner {
        require(!tradingEnabled, "Already enabled");
        tradingEnabled = true;
        emit TradingEnabled(block.timestamp);
    }

    function erebusTokenURI(uint256 id_) public view override returns (string memory) {
        return string.concat("https://your-metadata-endpoint/token/", Strings.toString(id_));
    }

    function setEREBUSExempt(address account_, bool value_, uint256 batchSize_)
        external onlyOwner
    {
        _setEREBUSExempt(account_, value_, batchSize_);
    }
}
```

### Compile

```bash
npm run build
```

### Test

```bash
npm run test
```

### Deploy

Copy `.env.example` to `.env` and fill in your keys:

```
DEPLOYER_PRIVATE_KEY=0x...
SEPOLIA_RPC_URL=https://...
MAINNET_RPC_URL=https://...
ETHERSCAN_API_KEY=...
```

Then:

```bash
# Sepolia testnet
npx hardhat run scripts/deployErebus.ts --network sepolia

# Mainnet
npx hardhat run scripts/deployErebus.ts --network mainnet
```

After computing the V3 pool address, exempt it and open trading:

```bash
EREBUS_ADDRESS=0x... POOL_ADDRESS=0x... npx hardhat run scripts/launch.ts --network mainnet
```

---

## Exemption management

DEX routers, LP pools, and other programmatic holders should be exempted from ERC-721 bookkeeping to avoid unnecessary NFT minting/burning on every trade.

For Uniswap V3, exempt the following before touching liquidity:

| Address | Purpose |
|---|---|
| SwapRouter02 | Passed as `router_` at deploy — auto-exempted |
| UniversalRouter (`0x3fC91A3afd70395...`) | Auto-exempted at deploy |
| NonfungiblePositionManager (`0xC36442b4...`) | Auto-exempted at deploy — needed for fee collection |
| V3 pool address | Exempt via `setupLiquidityPair` **before** adding LP |

For addresses with a small NFT balance, pass `type(uint256).max` to process everything in one call:

```solidity
setEREBUSExempt(routerAddress, true, type(uint256).max);
```

For addresses with hundreds of NFTs, call repeatedly with a bounded batch size:

```solidity
// First call
setEREBUSExempt(lpPool, true, 100);
// If it reverts with ExemptionStillPending, call again
setEREBUSExempt(lpPool, true, 100);
// ... repeat until it succeeds
```

---

## Key constants and storage layout

| Symbol | Value | Purpose |
|---|---|---|
| `ID_ENCODING_PREFIX` | `1 << 255` | High bit distinguishes NFT IDs from ERC-20 amounts |
| `_BITMASK_ADDRESS` | `(1 << 160) - 1` | Low 160 bits of `_ownedData` slot — owner address |
| `_BITMASK_OWNED_INDEX` | `((1 << 96) - 1) << 160` | High 96 bits of `_ownedData` slot — owned array index |

`_owned[address]` stores `uint32` offsets (not full `uint256` IDs). The full ID is `ID_ENCODING_PREFIX | uint256(offset)`. Maximum collection size: 2^32 (~4 billion tokens).

---

## Reference implementation

[Erebus](https://github.com/Erebus-451/erebus-labs) is a production deployment of ERC-451 on Ethereum mainnet. It implements the full trading gate pattern, EIP-4906 metadata, self-exemption, and a Uniswap V3 launch sequence.

---

## License

MIT — see [LICENSE](LICENSE).
