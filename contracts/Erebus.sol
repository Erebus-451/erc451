// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ERC451} from "./ERC451.sol";

/**
 * @title  Erebus
 * @notice ERC-451 semi-fungible token. 5,000 NFT max supply, 18 decimals.
 *         Each whole unit of EREBUS corresponds to one ERC-721 token.
 */
contract Erebus is ERC451, Ownable {

    uint256 public constant MAX_SUPPLY = 5_000;

    /// @param initialOwner_        Address that receives owner role.
    /// @param initialMintRecipient_ Address that receives the full ERC-20 supply.
    ///                              Exempted from ERC-721 bookkeeping on mint to save gas.
    constructor(
        address initialOwner_,
        address initialMintRecipient_
    )
        ERC451("Erebus", "EREBUS", 18)
        Ownable(initialOwner_)
    {
        // Exempt the mint recipient so the initial mint is a single ERC-20 transfer
        // with no per-token NFT minting overhead (mirrors ERC404Example pattern).
        _setERC721TransferExempt(initialMintRecipient_, true, type(uint256).max);
        _mintERC20(initialMintRecipient_, MAX_SUPPLY * units);
    }

    // =========================================================================
    // Metadata
    // =========================================================================

    /**
     * @notice Returns the metadata URI for ERC-721 token `id_`.
     * @dev    Override in production to point at your actual metadata endpoint.
     */
    function tokenURI(uint256 id_) public pure override returns (string memory) {
        return string.concat("https://metadata.erebuslabs.io/token/", Strings.toString(id_));
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
