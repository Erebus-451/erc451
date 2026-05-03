// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {ERC451} from "./ERC451.sol";


/**
 * @title  Erebus
 * @notice ERC-451 semi-fungible token. 1,000 NFT max supply, 18 decimals.
 *         Each whole unit of EREBUS corresponds to one ERC-721 token.
 */
contract Erebus is ERC451, Ownable {

    /// @dev EIP-4906: signals a metadata refresh for a range of token IDs.
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    /// @notice Emitted when a wallet exempts or re-enrolls itself.
    event SelfExemptionSet(address indexed account, bool exempt);

    /// @notice Emitted when the liquidity pair is configured.
    event LiquidityPairSet(address indexed pair, address indexed router);

    /// @notice Emitted once when trading is permanently opened.
    event TradingEnabled(uint256 timestamp);

    uint256 public constant MAX_SUPPLY = 1_000;

    string private _baseTokenURI;
    bool private _initialMinted;

    address public uniswapV2Pair;
    address public uniswapV2Router;

    /**
     * @param router_              Uniswap V2 router — stored and exempted immediately.
     * @param initialOwner_        Address that receives the owner role.
     * @param initialMintRecipient_ Address that will receive supply via initialMint().
     */
    constructor(
        address router_,
        address initialOwner_,
        address initialMintRecipient_
    )
        ERC451("Erebus", "EREBUS", 18)
        Ownable(initialOwner_)
    {
        _baseTokenURI = "ipfs://bafybeidc7vt4zn74njvgo6vetilstukcm4jww74azkvmf3nk3zari4nxgy/";

        uniswapV2Router = router_;

        // Exempt protocol addresses — batchSize=0 is safe before any NFT is minted.
        _setERC721TransferExempt(router_,               true, 0);
        _setERC721TransferExempt(initialOwner_,         true, 0);
        _setERC721TransferExempt(initialMintRecipient_, true, 0);
        // Burn address: ERC-20 burns here must not mint NFTs into dead storage.
        _setERC721TransferExempt(address(0x000000000000000000000000000000000000dEaD), true, 0);
    }

    // =========================================================================
    // Liquidity pair setup
    // =========================================================================

    /**
     * @notice Registers the EREBUS/WETH pair address and exempts it from NFT mechanics.
     * @dev    Does NOT call createPair on Uniswap. The pair address must be pre-computed
     *         off-chain using the CREATE2 formula (see deploy script). The actual pair
     *         is created by the Uniswap router on the first addLiquidity call, which is
     *         when PairCreated fires — at launch, not at deploy.
     * @param  pair_  Deterministic CREATE2 address of the EREBUS/WETH pair.
     */
    function setupLiquidityPair(address pair_) external onlyOwner {
        require(uniswapV2Pair == address(0), "Pair already set");
        uniswapV2Pair = pair_;
        _setERC721TransferExempt(pair_, true, 0);
        emit LiquidityPairSet(pair_, uniswapV2Router);
    }

    // =========================================================================
    // Trading gate
    // =========================================================================

    /**
     * @notice Permanently enables trading for non-exempt addresses. Cannot be undone.
     * @dev    One-time: reverts if tradingEnabled is already true.
     *         Call after setupLiquidityPair so the pair is exempt before buys open.
     */
    function enableTrading() external onlyOwner {
        require(!tradingEnabled, "Already enabled");
        tradingEnabled = true;
        emit TradingEnabled(block.timestamp);
    }

    // =========================================================================
    // Initial mint
    // =========================================================================

    /**
     * @notice Mints the full ERC-20 supply to `to_`. Can only be called once by owner.
     * @dev    Recipient must be exempt to avoid minting MAX_SUPPLY NFTs in one transaction.
     */
    function initialMint(address to_) external onlyOwner {
        require(!_initialMinted, "Already minted");
        _initialMinted = true;
        if (!erc721TransferExempt(to_)) {
            _setERC721TransferExempt(to_, true, 0);
        }
        _mintERC20(to_, MAX_SUPPLY * units);
    }

    // =========================================================================
    // Metadata
    // =========================================================================

    /// @notice Returns the metadata URI for ERC-721 token `id_`.
    function tokenURI(uint256 id_) public view override returns (string memory) {
        return string.concat(_baseTokenURI, Strings.toString(id_ ^ ID_ENCODING_PREFIX), ".json");
    }

    /// @notice Owner can update the base URI. Emits EIP-4906 BatchMetadataUpdate.
    function setBaseURI(string memory newURI_) external onlyOwner {
        _baseTokenURI = newURI_;
        emit BatchMetadataUpdate(1, type(uint256).max);
    }

    // =========================================================================
    // Self-exemption
    // =========================================================================

    /**
     * @notice Allows a wallet to opt out of receiving ERC-721 NFTs.
     *         Only the calling wallet can exempt itself — no one can exempt others.
     * @dev    tx.origin check blocks contracts from calling on behalf of users.
     * @param  exempt true to opt out of NFTs, false to opt back in.
     */
    function setSelfERC721TransferExempt(bool exempt) public override {
        require(msg.sender == tx.origin, "No contracts");
        _setERC721TransferExempt(msg.sender, exempt, type(uint256).max);
        emit SelfExemptionSet(msg.sender, exempt);
    }

    /// @notice Returns true if `account` is exempt from ERC-721 bookkeeping.
    function isERC721Exempt(address account) external view returns (bool) {
        return erc721TransferExempt(account);
    }

    // =========================================================================
    // Interface detection
    // =========================================================================

    /**
     * @notice Reports IERC165 only. Deliberately omits IERC721 so wallets (MetaMask)
     *         and token scanners treat this contract as ERC-20. The semi-fungible NFT
     *         side is still fully functional — Transfer events with 4 indexed topics
     *         are sufficient for marketplaces to discover and index the NFTs.
     */
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }

    // =========================================================================
    // Owner-gated admin
    // =========================================================================

    /**
     * @notice Owner can exempt/unexempt addresses (e.g. DEX routers, LP pools).
     * @param  batchSize_ Max NFTs to process per call. Use type(uint256).max for
     *                    small balances; call repeatedly for large ones (CRIT-06).
     */
    function setERC721TransferExempt(
        address account_,
        bool value_,
        uint256 batchSize_
    ) external onlyOwner {
        _setERC721TransferExempt(account_, value_, batchSize_);
    }
}
