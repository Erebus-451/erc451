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

import {IERC721Receiver} from "@openzeppelin/contracts/interfaces/IERC721Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";

abstract contract ERC451 is IERC165 {

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                            EVENTS                                */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event Transfer(address indexed from, address indexed to, uint256 value);
    event ERC20Approval(address indexed owner, address indexed spender, uint256 value);
    event ERC721Approval(address indexed owner, address indexed spender, uint256 indexed id);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    /// @dev EIP-4906 — COMP-06: signal metadata refresh on recycled token IDs
    event MetadataUpdate(uint256 indexed tokenId);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                            ERRORS                                */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    error NotFound(uint256 id);
    error InvalidTokenId(uint256 id);
    error AlreadyExists(uint256 id);
    error InvalidRecipient(address to);
    error InvalidSender(address from);
    error InvalidSpender(address spender);
    error InvalidOperator(address operator);
    error UnsafeRecipient(address to);
    error RecipientIsERC721TransferExempt(address to);
    error Unauthorized(address caller, uint256 id);
    /// @dev COMP-02: replaces silent arithmetic underflow
    error InsufficientAllowance(address owner, address spender, uint256 needed, uint256 available);
    error DecimalsTooLow();
    error PermitDeadlineExpired();
    error InvalidSigner();
    error InvalidApproval();
    error OwnedIndexOverflow();
    error MintLimitReached();
    error InvalidExemption();
    error Reentrancy();
    error ExemptionStillPending(address target, uint256 remaining);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                            STORAGE                               */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Token name (ERC-20 + ERC-721)
    string public name;

    /// @notice Token symbol (ERC-20 + ERC-721)
    string public symbol;

    /// @notice ERC-20 decimals — must be >= 18
    uint8 public immutable decimals;

    /// @notice One whole token in ERC-20 units (10 ** decimals)
    uint256 public immutable units;

    // =========================================================================
    // Supply tracking
    // =========================================================================

    /// @notice Total ERC-20 supply
    uint256 public totalSupply;

    /**
     * @notice Monotonically-increasing mint counter.
     * @dev Highest minted offset, independent from live circulating count.
     */
    uint256 public minted;

    // =========================================================================
    // ERC-20 state
    // =========================================================================

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // =========================================================================
    // ERC-721 state
    // =========================================================================

    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    /**
     * @dev Packed per-token slot: bits 0-159 = owner address, bits 160-255 = index in _owned.
     *      Both fields are written in a single SSTORE via _setOwnerAndIndex (CRIT-02).
     */
    mapping(uint256 => uint256) internal _ownedData;

    /**
     * @dev GAS-03: uint32[] stores only the offset from ID_ENCODING_PREFIX, not the full uint256 ID.
     *      Solidity packs 8 × uint32 per storage slot — 8× cheaper than uint256[].
     *      Maximum collection size: 2^32 (~4 billion tokens).
     */
    mapping(address => uint32[]) internal _owned;

    // =========================================================================
    // Transfer-exempt set
    // =========================================================================

    mapping(address => bool) internal _erebusTransferExempt;

    // =========================================================================
    // Trading gate
    // =========================================================================

    /// @notice False until owner calls startEREBUS(). Prevents non-exempt transfers at launch.
    bool public tradingEnabled;

    // =========================================================================
    // Bank queue (recycled NFT IDs)
    // =========================================================================

    /**
     * @dev Packed head (low 128 bits) and tail (high 128 bits) in one slot.
     *      Saves one SLOAD/SSTORE vs two separate uint256 variables.
     */
    uint256 private _bankPointers;
    mapping(uint256 => uint32) private _bankData;

    // =========================================================================
    // EIP-2612 permit
    // =========================================================================

    mapping(address => uint256) public nonces;
    uint256 internal immutable _INITIAL_CHAIN_ID;
    bytes32 internal immutable _INITIAL_DOMAIN_SEPARATOR;

    // =========================================================================
    // Reentrancy guard (CRIT-03)
    // =========================================================================

    uint8 private _reentrancyLock;

    // =========================================================================
    // Constants
    // =========================================================================

    /// @dev High bit set on all ERC-721 token IDs to distinguish them from ERC-20 amounts.
    uint256 public constant ID_ENCODING_PREFIX = 1 << 255;

    /// @dev keccak256("Transfer(address,address,uint256)") — shared by ERC-20 and ERC-721 Transfer events.
    bytes32 private constant _TRANSFER_EVENT_SIGNATURE = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    uint256 private constant _BITMASK_ADDRESS     = (1 << 160) - 1;
    uint256 private constant _BITMASK_OWNED_INDEX = ((1 << 96) - 1) << 160;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          CONSTRUCTOR                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        if (decimals_ < 18) revert DecimalsTooLow();
        name     = name_;
        symbol   = symbol_;
        decimals = decimals_;
        units    = 10 ** decimals_;

        _INITIAL_CHAIN_ID         = block.chainid;
        _INITIAL_DOMAIN_SEPARATOR = _computeDomainSeparator();
    }

    // =========================================================================
    // Modifiers
    // =========================================================================

    /// @dev CRIT-03: guards any function that makes an external call (onERC721Received)
    modifier nonReentrant() {
        if (_reentrancyLock != 0) revert Reentrancy();
        _reentrancyLock = 1;
        _;
        _reentrancyLock = 0;
    }

    // =========================================================================
    // ERC-165 (CRIT-05)
    // =========================================================================

    /**
     * @notice CRIT-05: reports IERC721 (0x80ac58cd) and IERC721Metadata (0x5b5e139f)
     *         so NFT marketplaces (OpenSea, Blur) correctly identify this as an NFT.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IERC165).interfaceId ||
            interfaceId == 0x80ac58cd ||   // IERC721
            interfaceId == 0x5b5e139f;     // IERC721Metadata
    }

    // =========================================================================
    // ERC-721 views
    // =========================================================================

    /// @notice Returns the owner of ERC-721 token `id_`.
    function ownerOf(uint256 id_) public view virtual returns (address owner) {
        // QUAL-04: _isNFTId checks range; does not imply the token is minted
        if (!_isNFTId(id_)) revert InvalidTokenId(id_);
        owner = _getOwner(id_);
        if (owner == address(0)) revert NotFound(id_);
    }

    /**
     * @notice Returns a page of token IDs owned by `owner_`.
     */
    function owned(
        address owner_,
        uint256 start_,
        uint256 count_
    ) public view virtual returns (uint256[] memory ids) {
        uint32[] storage ownerSlot = _owned[owner_];
        uint256 len = ownerSlot.length;
        if (start_ >= len) return new uint256[](0);
        uint256 end = start_ + count_;
        if (end > len) end = len;
        uint256 size = end - start_;
        ids = new uint256[](size);
        for (uint256 i = 0; i < size; ) {
            ids[i] = ID_ENCODING_PREFIX | uint256(ownerSlot[start_ + i]);
            unchecked { ++i; }
        }
    }

    /// @notice Full owned array — use owned(owner, start, count) for large holders.
    function owned(address owner_) public view virtual returns (uint256[] memory ids) {
        return owned(owner_, 0, _owned[owner_].length);
    }

    function erebusBalanceOf(address owner_) public view virtual returns (uint256) {
        return _owned[owner_].length;
    }

    /// @notice Returns live circulating NFTs.
    function erebusCirculatingSupply() public view virtual returns (uint256) {
        return minted - _bankLength();
    }

    /**
     * @notice Returns the highest token ID offset ever minted (monotonic, never decreases).
     * @dev    Named clearly to distinguish from circulating supply (CRIT-04).
     */
    function erebusHighestMintedId() public view virtual returns (uint256) {
        return minted;
    }

    function getEREBUSQueueLength() public view virtual returns (uint256) {
        return _bankLength();
    }

    /// @notice Returns a page of token IDs currently in the bank queue.
    function getEREBUSTokensInQueue(
        uint256 start_,
        uint256 count_
    ) public view virtual returns (uint256[] memory ids) {
        uint256 qLen = _bankLength();
        // GAS-08: bounds check before memory allocation to avoid wasted allocation on revert
        if (start_ + count_ > qLen) revert OwnedIndexOverflow();
        ids = new uint256[](count_);
        uint256 head = _bankHead();
        for (uint256 i = 0; i < count_; ) {
            ids[i] = ID_ENCODING_PREFIX | uint256(_bankData[head + start_ + i]);
            unchecked { ++i; }
        }
    }

    // =========================================================================
    // ERC-20 views
    // =========================================================================

    function erc20BalanceOf(address owner_) public view virtual returns (uint256) {
        return balanceOf[owner_];
    }

    function erebusTotalSupply() public view virtual returns (uint256) {
        return totalSupply;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           METADATA                               */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function erebusTokenURI(uint256 id_) public view virtual returns (string memory);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          EXEMPTIONS                              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function erebusTransferExempt(address target_) public view virtual returns (bool) {
        return target_ == address(0) || _erebusTransferExempt[target_];
    }

    /// @notice Allows any holder to exempt themselves from ERC-721 bookkeeping.
    function setSelfEREBUSExempt(bool state_) public virtual {
        _setEREBUSExempt(msg.sender, state_, type(uint256).max);
    }

    // =========================================================================
    // Approvals
    // =========================================================================

    /**
     * @notice Unified approve — dispatches to ERC-721 if valueOrId_ is in the NFT ID
     *         range, otherwise ERC-20. COMP-01: dispatch boundary is clearly documented.
     * @dev    ERC-20 unlimited approval: use type(uint256).max (excluded from NFT range).
     *         Any value > ID_ENCODING_PREFIX and != type(uint256).max is an NFT ID.
     */
    function approve(address spender_, uint256 valueOrId_) public virtual returns (bool) {
        if (_isNFTId(valueOrId_)) {
            erc721Approve(spender_, valueOrId_);
        } else {
            return erc20Approve(spender_, valueOrId_);
        }
        return true;
    }

    function erc721Approve(address spender_, uint256 id_) public virtual {
        address owner = _getOwner(id_);
        if (msg.sender != owner && !isApprovedForAll[owner][msg.sender])
            revert Unauthorized(msg.sender, id_);
        getApproved[id_] = spender_;
        emit ERC721Approval(owner, spender_, id_);
    }

    function erc20Approve(address spender_, uint256 value_) public virtual returns (bool) {
        if (spender_ == address(0)) revert InvalidSpender(spender_);
        allowance[msg.sender][spender_] = value_;
        emit ERC20Approval(msg.sender, spender_, value_);
        return true;
    }

    function setApprovalForAll(address operator_, bool approved_) public virtual {
        if (operator_ == address(0)) revert InvalidOperator(operator_);
        isApprovedForAll[msg.sender][operator_] = approved_;
        emit ApprovalForAll(msg.sender, operator_, approved_);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        TRANSFER LOGIC                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Unified transferFrom — dispatches to ERC-721 or ERC-20 based on valueOrId_.
     */
    function transferFrom(
        address from_,
        address to_,
        uint256 valueOrId_
    ) public virtual returns (bool) {
        if (_isNFTId(valueOrId_)) {
            erc721TransferFrom(from_, to_, valueOrId_);
        } else {
            return erc20TransferFrom(from_, to_, valueOrId_);
        }
        return true;
    }

    /**
     * @notice Direct ERC-721 transfer. Moves one NFT and its corresponding ERC-20 unit.
     */
    function erc721TransferFrom(address from_, address to_, uint256 id_) public virtual {
        if (from_ == address(0)) revert InvalidSender(from_);
        if (to_   == address(0)) revert InvalidRecipient(to_);
        if (from_ != _getOwner(id_))  revert Unauthorized(msg.sender, id_);
        if (
            msg.sender != from_ &&
            !isApprovedForAll[from_][msg.sender] &&
            msg.sender != getApproved[id_]
        ) revert Unauthorized(msg.sender, id_);
        if (erebusTransferExempt(to_)) revert RecipientIsERC721TransferExempt(to_);

        _transferERC20(from_, to_, units);
        _transferERC721(from_, to_, id_);
    }

    /**
     * @notice ERC-20 transferFrom with explicit InsufficientAllowance error (COMP-02).
     */
    function erc20TransferFrom(
        address from_,
        address to_,
        uint256 value_
    ) public virtual returns (bool) {
        if (from_ == address(0)) revert InvalidSender(from_);
        if (to_   == address(0)) revert InvalidRecipient(to_);

        uint256 allowed = allowance[from_][msg.sender];
        // COMP-02: explicit error instead of silent arithmetic underflow
        if (allowed != type(uint256).max) {
            if (value_ > allowed)
                revert InsufficientAllowance(from_, msg.sender, value_, allowed);
            unchecked { allowance[from_][msg.sender] = allowed - value_; }
        }

        return _transferERC20WithERC721(from_, to_, value_);
    }

    /**
     * @notice ERC-20 transfer (self-initiated, always treated as ERC-20).
     */
    function transfer(address to_, uint256 value_) public virtual returns (bool) {
        if (to_ == address(0)) revert InvalidRecipient(to_);
        return _transferERC20WithERC721(msg.sender, to_, value_);
    }

    /**
     * @notice ERC-721 safeTransferFrom with reentrancy guard (CRIT-03).
     */
    function safeTransferFrom(address from_, address to_, uint256 id_) public virtual {
        safeTransferFrom(from_, to_, id_, "");
    }

    /**
     * @notice ERC-721 safeTransferFrom with callback data and reentrancy guard (CRIT-03).
     * @dev    nonReentrant covers the full call including the onERC721Received callback,
     *         preventing re-entry into any ERC-451 state-mutating function.
     */
    function safeTransferFrom(
        address from_,
        address to_,
        uint256 id_,
        bytes memory data_
    ) public virtual nonReentrant {
        if (!_isNFTId(id_)) revert InvalidTokenId(id_);

        // Effects first (CEI), then interaction
        erc721TransferFrom(from_, to_, id_);

        if (
            to_.code.length != 0 &&
            IERC721Receiver(to_).onERC721Received(msg.sender, from_, id_, data_) !=
            IERC721Receiver.onERC721Received.selector
        ) revert UnsafeRecipient(to_);
    }

    // =========================================================================
    // EIP-2612 permit
    // =========================================================================

    /**
     * @notice EIP-2612 signature-based ERC-20 approval.
     * @dev    COMP-05: guards against owner_ == address(0) before nonce increment.
     */
    function permit(
        address owner_,
        address spender_,
        uint256 value_,
        uint256 deadline_,
        uint8 v_,
        bytes32 r_,
        bytes32 s_
    ) public virtual {
        if (deadline_ < block.timestamp) revert PermitDeadlineExpired();
        if (_isNFTId(value_))            revert InvalidApproval();
        if (spender_ == address(0))      revert InvalidSpender(spender_);
        // COMP-05: reject address(0) owner before any state change
        if (owner_ == address(0))        revert InvalidSigner();

        unchecked {
            address recovered = ecrecover(
                keccak256(abi.encodePacked(
                    "\x19\x01",
                    DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        owner_,
                        spender_,
                        value_,
                        nonces[owner_]++,
                        deadline_
                    ))
                )),
                v_, r_, s_
            );
            if (recovered == address(0) || recovered != owner_) revert InvalidSigner();
            allowance[recovered][spender_] = value_;
        }

        emit ERC20Approval(owner_, spender_, value_);
    }

    function DOMAIN_SEPARATOR() public view virtual returns (bytes32) {
        return block.chainid == _INITIAL_CHAIN_ID
            ? _INITIAL_DOMAIN_SEPARATOR
            : _computeDomainSeparator();
    }

    // =========================================================================
    // Internal — ERC-20 layer
    // =========================================================================

    /**
     * @dev Raw ERC-20 transfer with no NFT side-effects. Allows address(0) as from (mint).
     *      Trading gate: before enableTrading(), at least one of from/to must be exempt.
     *      address(0) is always exempt so mints are never blocked.
     */
    function _transferERC20(address from_, address to_, uint256 value_) internal virtual {
        if (!tradingEnabled) {
            require(
                erebusTransferExempt(from_) || erebusTransferExempt(to_),
                "Trading not enabled"
            );
        }
        if (from_ == address(0)) {
            totalSupply += value_;
        } else {
            balanceOf[from_] -= value_;
        }
        unchecked { balanceOf[to_] += value_; }
        emit Transfer(from_, to_, value_);
    }

    /**
     * @dev  Core semi-fungible transfer: moves ERC-20 and reconciles ERC-721 holdings.
     *
     *       GAS-01: post-transfer balances are computed arithmetically from pre-transfer
     *               values rather than re-reading storage after _transferERC20.
     *
     *       Case 1 — both exempt:         pure ERC-20 move, no NFT work.
     *       Case 2 — sender exempt only:  mint/retrieve NFTs for recipient delta.
     *       Case 3 — recipient exempt:    bank NFTs from sender delta.
     *       Case 4 — neither exempt:      batch-transfer whole NFTs, handle fractional boundary.
     */
    function _transferERC20WithERC721(
        address from_,
        address to_,
        uint256 value_
    ) internal virtual returns (bool) {
        uint256 senderBefore   = erc20BalanceOf(from_);
        uint256 receiverBefore = erc20BalanceOf(to_);

        _transferERC20(from_, to_, value_);

        // GAS-01: derive post-transfer balances without additional SLOADs
        uint256 senderAfter   = senderBefore   - value_;
        uint256 receiverAfter = receiverBefore + value_;

        bool fromExempt = erebusTransferExempt(from_);
        bool toExempt   = erebusTransferExempt(to_);

        if (fromExempt && toExempt) {
            // Case 1: no NFT work
        } else if (fromExempt) {
            // Case 2: recipient gains whole tokens — retrieve/mint NFTs
            uint256 toMint = (receiverAfter / units) - (receiverBefore / units);
            for (uint256 i = 0; i < toMint; ) {
                _retrieveOrMintERC721(to_);
                unchecked { ++i; }
            }
        } else if (toExempt) {
            // Case 3: sender loses whole tokens — bank their NFTs
            uint256 toBank = (senderBefore / units) - (senderAfter / units);
            for (uint256 i = 0; i < toBank; ) {
                _withdrawAndStoreERC721(from_);
                unchecked { ++i; }
            }
        } else {
            // Case 4: CRIT-01 improvement — batch NFT transfer for whole tokens,
            // then handle fractional boundary with at most one additional mint/bank.
            uint256 nftsToTransfer = value_ / units;
            if (nftsToTransfer > 0) {
                _batchTransferFromOwned(from_, to_, nftsToTransfer);
            }

            // Fractional sender boundary: did losing the fraction drop a whole token?
            if ((senderBefore / units) - (senderAfter / units) > nftsToTransfer) {
                _withdrawAndStoreERC721(from_);
            }

            // Fractional receiver boundary: did gaining the fraction complete a whole token?
            if ((receiverAfter / units) - (receiverBefore / units) > nftsToTransfer) {
                _retrieveOrMintERC721(to_);
            }
        }

        return true;
    }

    /// @dev Dedicated mint path.
    function _mintERC20(address to_, uint256 value_) internal virtual {
        if (to_ == address(0)) revert InvalidRecipient(to_);
        if (totalSupply + value_ > ID_ENCODING_PREFIX) revert MintLimitReached();

        uint256 receiverBefore = erc20BalanceOf(to_);

        // Increase supply and recipient balance
        totalSupply += value_;
        unchecked { balanceOf[to_] += value_; }
        emit Transfer(address(0), to_, value_);

        // GAS-06: if recipient is not exempt, mint NFTs directly without going
        //         through the full transfer dispatch
        if (!erebusTransferExempt(to_)) {
            uint256 receiverAfter = receiverBefore + value_;
            uint256 toMint = (receiverAfter / units) - (receiverBefore / units);
            for (uint256 i = 0; i < toMint; ) {
                _retrieveOrMintERC721(to_);
                unchecked { ++i; }
            }
        }
    }

    // =========================================================================
    // Internal — ERC-721 layer
    // =========================================================================

    /**
     * @dev Single ERC-721 transfer — used for explicit erc721TransferFrom calls.
     *      CRIT-02: uses _setOwnerAndIndex for a single SSTORE on _ownedData.
     *      Note: does NOT emit an ERC-20 Transfer event. The caller is responsible
     *      for any accompanying ERC-20 movement (COMP-03).
     */
    function _transferERC721(address from_, address to_, uint256 id_) internal virtual {
        if (from_ != address(0)) {
            delete getApproved[id_];
            _removeFromOwned(from_, id_);
        }

        if (to_ != address(0)) {
            uint32[] storage toOwned = _owned[to_];
            uint256 newIndex = toOwned.length;
            // GAS-03: store only the uint32 offset, not the full uint256 ID
            toOwned.push(uint32(id_ & type(uint32).max));
            // CRIT-02: single SSTORE for owner + index (was two separate read-modify-writes)
            _setOwnerAndIndex(id_, to_, newIndex);
        } else {
            // Burn: clear ownership data entirely
            delete _ownedData[id_];
        }

        // ERC-721 Transfer: 4 topics (from, to, id all indexed) — distinguishes NFT transfer
        // from the 3-topic ERC-20 Transfer emitted by _transferERC20.
        assembly {
            log4(0, 0, _TRANSFER_EVENT_SIGNATURE, from_, to_, id_)
        }
    }

    /// @dev Batch-transfers `count_` NFTs from sender tail to recipient.
    function _batchTransferFromOwned(
        address from_,
        address to_,
        uint256 count_
    ) internal virtual {
        uint32[] storage fromOwned = _owned[from_];
        uint32[] storage toOwned   = _owned[to_];
        uint256 fromLen  = fromOwned.length;
        uint256 toLen    = toOwned.length;

        for (uint256 i = 0; i < count_; ) {
            // Read offset from the tail of sender's array (no swap needed)
            uint32  offset = fromOwned[fromLen - 1 - i];
            uint256 id     = ID_ENCODING_PREFIX | uint256(offset);

            delete getApproved[id];

            // Append to recipient
            toOwned.push(offset);
            // CRIT-02: single combined SSTORE for owner + index
            _setOwnerAndIndex(id, to_, toLen + i);

            assembly {
                log4(0, 0, _TRANSFER_EVENT_SIGNATURE, from_, to_, id)
            }
            unchecked { ++i; }
        }

        // Pop `count_` elements from the sender's tail
        // (their _ownedData has already been overwritten with new owner above)
        for (uint256 i = 0; i < count_; ) {
            fromOwned.pop();
            unchecked { ++i; }
        }
    }

    /**
     * @dev Removes `id_` from `_owned[from_]` using swap-and-pop.
     *      Called for single-token operations (explicit ERC-721 transfers).
     */
    function _removeFromOwned(address from_, uint256 id_) private {
        uint32[] storage fromOwned = _owned[from_];
        uint256 lastIndex = fromOwned.length - 1;
        uint256 removeIndex = _getOwnedIndex(id_);

        if (removeIndex != lastIndex) {
            // Swap the last element into the removed slot
            uint32 lastOffset = fromOwned[lastIndex];
            fromOwned[removeIndex] = lastOffset;
            // Update the moved token's index in _ownedData
            // CRIT-02: preserve owner, update only index
            uint256 movedId = ID_ENCODING_PREFIX | uint256(lastOffset);
            address movedOwner = _getOwner(movedId);
            _setOwnerAndIndex(movedId, movedOwner, removeIndex);
        }

        fromOwned.pop();
    }

    /**
     * @dev Retrieves the oldest banked NFT or mints a new one, assigns to `to_`.
     *      COMP-06: emits MetadataUpdate when recycling a previously-used token ID.
     */
    function _retrieveOrMintERC721(address to_) internal virtual {
        if (to_ == address(0)) revert InvalidRecipient(to_);

        uint256 id;
        bool recycled = !_bankEmpty();

        if (recycled) {
            // FIFO: pop the oldest stored ID from the bank
            id = ID_ENCODING_PREFIX | uint256(_bankPop());
        } else {
            unchecked { ++minted; }
            if (minted > type(uint32).max) revert MintLimitReached();
            id = ID_ENCODING_PREFIX | minted;
        }

        if (_getOwner(id) != address(0)) revert AlreadyExists(id);

        _transferERC721(address(0), to_, id);

        // COMP-06: signal stale marketplace metadata caches on token ID reuse
        if (recycled) emit MetadataUpdate(id);
    }

    /**
     * @dev Banks the most recently acquired NFT from `from_` (LIFO within sender's stack).
     */
    function _withdrawAndStoreERC721(address from_) internal virtual {
        if (from_ == address(0)) revert InvalidSender(from_);

        // GAS-04: cache storage reference, avoid double dereference
        uint32[] storage fromOwned = _owned[from_];
        uint256 lastIndex = fromOwned.length - 1;
        uint256 id = ID_ENCODING_PREFIX | uint256(fromOwned[lastIndex]);

        _transferERC721(from_, address(0), id);
        _bankPush(uint32(id & type(uint32).max));
    }

    // =========================================================================
    // Internal — exemption management (CRIT-06)
    // =========================================================================

    /// @dev Paginated exemption toggle.
    function _setEREBUSExempt(
        address target_,
        bool state_,
        uint256 batchSize_
    ) internal virtual {
        if (target_ == address(0)) revert InvalidExemption();

        if (state_) {
            _clearERC721Balance(target_, batchSize_);
            // Only mark exempt once the balance is fully cleared
            if (_owned[target_].length == 0) {
                _erebusTransferExempt[target_] = true;
            } else {
                // Caller must continue calling with additional batches
                revert ExemptionStillPending(target_, _owned[target_].length);
            }
        } else {
            _erebusTransferExempt[target_] = false;
            _reinstateERC721Balance(target_, batchSize_);
        }
    }

    /**
     * @dev Banks up to `batchSize_` NFTs from `target_` during exemption set.
     */
    function _clearERC721Balance(address target_, uint256 batchSize_) private {
        uint256 balance = _owned[target_].length;
        uint256 toProcess = balance < batchSize_ ? balance : batchSize_;
        for (uint256 i = 0; i < toProcess; ) {
            _withdrawAndStoreERC721(target_);
            unchecked { ++i; }
        }
    }

    /**
     * @dev Retrieves/mints up to `batchSize_` NFTs for `target_` during exemption removal.
     */
    function _reinstateERC721Balance(address target_, uint256 batchSize_) private {
        uint256 expected = erc20BalanceOf(target_) / units;
        uint256 actual   = erebusBalanceOf(target_);
        if (expected <= actual) return;
        uint256 toMint = expected - actual;
        if (toMint > batchSize_) toMint = batchSize_;
        for (uint256 i = 0; i < toMint; ) {
            _retrieveOrMintERC721(target_);
            unchecked { ++i; }
        }
    }

    // =========================================================================
    // Internal — packed ownership helpers (CRIT-02)
    // =========================================================================

    /// @dev Encodes owner and index into one packed storage slot.
    function _setOwnerAndIndex(uint256 id_, address owner_, uint256 index_) internal {
        if (index_ > type(uint96).max) revert OwnedIndexOverflow();
        assembly {
            // or is semantically correct for non-overlapping bit fields (QUAL-08)
            let packed := or(
                and(owner_, _BITMASK_ADDRESS),
                and(shl(160, index_), _BITMASK_OWNED_INDEX)
            )
            // Compute storage slot: _ownedData[id_]
            mstore(0x00, id_)
            mstore(0x20, _ownedData.slot)
            sstore(keccak256(0x00, 0x40), packed)
        }
    }

    function _getOwner(uint256 id_) internal view returns (address owner_) {
        uint256 data = _ownedData[id_];
        assembly { owner_ := and(data, _BITMASK_ADDRESS) }
    }

    function _getOwnedIndex(uint256 id_) internal view returns (uint256 index_) {
        uint256 data = _ownedData[id_];
        assembly { index_ := shr(160, data) }
    }

    // =========================================================================
    // Internal — bank queue helpers (packed head/tail)
    // =========================================================================

    /// @dev Returns the head pointer (low 128 bits of _bankPointers).
    function _bankHead() private view returns (uint128) {
        return uint128(_bankPointers);
    }

    /// @dev Returns the tail pointer (high 128 bits of _bankPointers).
    function _bankTail() private view returns (uint128) {
        return uint128(_bankPointers >> 128);
    }

    function _bankEmpty() private view returns (bool) {
        return uint128(_bankPointers) == uint128(_bankPointers >> 128);
    }

    function _bankLength() private view returns (uint256) {
        return uint256(_bankTail()) - uint256(_bankHead());
    }

    /// @dev Enqueues `offset_` at the tail (FIFO push).
    function _bankPush(uint32 offset_) private {
        uint128 tail = _bankTail();
        _bankData[tail] = offset_;
        // Update tail in high 128 bits, preserve head in low 128 bits
        _bankPointers = (_bankPointers & type(uint128).max) | (uint256(tail + 1) << 128);
    }

    /// @dev Dequeues from the head (FIFO pop), clears the vacated slot for gas refund.
    function _bankPop() private returns (uint32 offset_) {
        uint128 head = _bankHead();
        offset_ = _bankData[head];
        delete _bankData[head];
        // Update head in low 128 bits, preserve tail in high 128 bits
        _bankPointers = (_bankPointers & ~uint256(type(uint128).max)) | uint256(head + 1);
    }

    // =========================================================================
    // Internal — ID range helpers (QUAL-04)
    // =========================================================================

    /**
     * @dev  QUAL-04: renamed from _isValidTokenId. Returns true if `value_` falls
     *       in the NFT ID space (> ID_ENCODING_PREFIX, != type(uint256).max).
     *       Does NOT imply the token is minted — use _isMintedTokenId for that.
     */
    function _isNFTId(uint256 value_) internal pure returns (bool) {
        return value_ > ID_ENCODING_PREFIX && value_ != type(uint256).max;
    }

    /**
     * @dev  QUAL-04: returns true only if the token has been minted (offset <= minted)
     *       and is in the NFT ID space.
     */
    function _isMintedTokenId(uint256 id_) internal view returns (bool) {
        if (!_isNFTId(id_)) return false;
        uint256 offset = id_ ^ ID_ENCODING_PREFIX;
        return offset >= 1 && offset <= minted;
    }

    // =========================================================================
    // EIP-2612 internals
    // =========================================================================

    function _computeDomainSeparator() internal view virtual returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(name)),
            keccak256("1"),
            block.chainid,
            address(this)
        ));
    }
}
