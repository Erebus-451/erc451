// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
 * ═══════════════════════════════════════════════════════════════════
 *
 *                         E R E B U S
 *
 *                  The standard they didn't want you to have.
 *                  HTTP 451 — Unavailable For Legal Reasons.
 *
 *                  https://erebus.build
 *                  https://x.com/Erebus_build
 *                  https://github.com/Erebus-451
 *
 * ═══════════════════════════════════════════════════════════════════
 */

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

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                            EVENTS                                */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev EIP-4906: signals a metadata refresh for a range of token IDs.
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    /// @notice Emitted when a wallet exempts or re-enrolls itself.
    event SelfExemptionSet(address indexed account, bool exempt);

    /// @notice Emitted when the liquidity pool is configured.
    event LiquidityPairSet(address indexed pair, address indexed router);

    /// @notice Emitted once when trading is permanently opened.
    event TradingEnabled(uint256 timestamp);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                            STORAGE                               */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    uint256 public constant MAX_SUPPLY = 1_000;

    string private _erebusBaseURI;
    bool private _initialMinted;

    address public erebusPair;
    address public erebusRouter;
    address public constant UNIVERSAL_ROUTER = 0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          CONSTRUCTOR                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Sets routers and default exempt addresses.
    constructor(
        address router_,
        address initialOwner_,
        address initialMintRecipient_
    )
        ERC451("Erebus", "EREBUS", 18)
        Ownable(initialOwner_)
    {
        _erebusBaseURI = "ipfs://bafybeidc7vt4zn74njvgo6vetilstukcm4jww74azkvmf3nk3zari4nxgy/";

        erebusRouter = router_;

        _setEREBUSExempt(router_, true, 0);
        _setEREBUSExempt(UNIVERSAL_ROUTER, true, 0);
        _setEREBUSExempt(initialOwner_, true, 0);
        _setEREBUSExempt(initialMintRecipient_, true, 0);
        _setEREBUSExempt(address(0x000000000000000000000000000000000000dEaD), true, 0);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        TRANSFER LOGIC                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Registers the EREBUS pool address and exempts it.
    function setupEREBUSPair(address pair_) external onlyOwner {
        require(erebusPair == address(0), "Pair already set");
        erebusPair = pair_;
        _setEREBUSExempt(pair_, true, 0);
        emit LiquidityPairSet(pair_, erebusRouter);
    }

    /// @notice Opens transfers for non-exempt addresses.
    function startEREBUS() external onlyOwner {
        require(!tradingEnabled, "Already enabled");
        tradingEnabled = true;
        emit TradingEnabled(block.timestamp);
    }

    /// @notice Mints full supply once.
    function initialEREBUSMint(address to_) external onlyOwner {
        require(!_initialMinted, "Already minted");
        _initialMinted = true;
        if (!erebusTransferExempt(to_)) {
            _setEREBUSExempt(to_, true, 0);
        }
        _mintERC20(to_, MAX_SUPPLY * units);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           METADATA                               */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Returns the metadata URI for ERC-721 token `id_`.
    function erebusTokenURI(uint256 id_) public view override returns (string memory) {
        return string.concat(_erebusBaseURI, Strings.toString(id_ ^ ID_ENCODING_PREFIX), ".json");
    }

    /// @notice Owner can update the base URI. Emits EIP-4906 BatchMetadataUpdate.
    function setEREBUSBaseURI(string memory newURI_) external onlyOwner {
        _erebusBaseURI = newURI_;
        emit BatchMetadataUpdate(1, type(uint256).max);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          EXEMPTIONS                              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Allows a wallet to opt out of receiving ERC-721 NFTs.
     *         Only the calling wallet can exempt itself — no one can exempt others.
     * @dev    tx.origin check blocks contracts from calling on behalf of users.
     * @param  exempt true to opt out of NFTs, false to opt back in.
     */
    function setSelfEREBUSExempt(bool exempt) public override {
        require(msg.sender == tx.origin, "No contracts");
        _setEREBUSExempt(msg.sender, exempt, type(uint256).max);
        emit SelfExemptionSet(msg.sender, exempt);
    }

    /// @notice Returns true if `account` is exempt from ERC-721 bookkeeping.
    function isEREBUSExempt(address account) external view returns (bool) {
        return erebusTransferExempt(account);
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

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                             OWNER                                */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Owner can exempt/unexempt addresses (e.g. DEX routers, LP pools).
     * @param  batchSize_ Max NFTs to process per call. Use type(uint256).max for
     *                    small balances; call repeatedly for large ones (CRIT-06).
     */
    function setEREBUSExempt(
        address account_,
        bool value_,
        uint256 batchSize_
    ) external onlyOwner {
        _setEREBUSExempt(account_, value_, batchSize_);
    }
}
