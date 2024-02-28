// SPDX-License-Identifier: MIT
//  _____     _ _         _         _
// |_   _|_ _(_) |_____  | |   __ _| |__ ___
//   | |/ _` | | / / _ \ | |__/ _` | '_ (_-<
//   |_|\__,_|_|_\_\___/ |____\__,_|_.__/__/
//
//   Email: security@taiko.xyz
//   Website: https://taiko.xyz
//   GitHub: https://github.com/taikoxyz
//   Discord: https://discord.gg/taikoxyz
//   Twitter: https://twitter.com/taikoxyz
//   Blog: https://mirror.xyz/labs.taiko.eth
//   Youtube: https://www.youtube.com/@taikoxyz

pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../bridge/IBridge.sol";
import "../libs/LibAddress.sol";
import "./BridgedERC20.sol";
import "./BaseVault.sol";

/// @title ERC20Vault
/// @custom:security-contact security@taiko.xyz
/// @dev Labeled in AddressResolver as "erc20_vault"
/// @notice This vault holds all ERC20 tokens (excluding Ether) that users have
/// deposited. It also manages the mapping between canonical ERC20 tokens and
/// their bridged tokens.
contract ERC20Vault is BaseVault {
    using LibAddress for address;
    using SafeERC20 for IERC20;

    // Structs for canonical ERC20 tokens and transfer operations
    struct CanonicalERC20 {
        uint64 chainId;
        address addr;
        uint8 decimals;
        string symbol;
        string name;
    }

    struct BridgeTransferOp {
        uint64 destChainId;
        address destOwner;
        address to;
        address token;
        uint256 amount;
        uint256 gasLimit;
        uint256 fee;
        address refundTo;
        string memo;
    }

    // Mappings from btokens to their canonical tokens.
    mapping(address btoken => CanonicalERC20 cannonical) public bridgedToCanonical;

    // Mappings from canonical tokens to their btokens. Also storing chainId for
    // tokens across other chains aside from Ethereum.
    mapping(uint256 chainId => mapping(address ctoken => address btoken)) public canonicalToBridged;

    mapping(address btoken => bool blacklisted) public btokenBlacklist;

    uint256[47] private __gap;

    event BridgedTokenDeployed(
        uint256 indexed srcChainId,
        address indexed ctoken,
        address indexed btoken,
        string ctokenSymbol,
        string ctokenName,
        uint8 ctokenDecimal
    );

    event BridgedTokenChanged(
        uint256 indexed srcChainId,
        address indexed ctoken,
        address btokenOld,
        address btokenNew,
        string ctokenSymbol,
        string ctokenName,
        uint8 ctokenDecimal
    );

    event TokenSent(
        bytes32 indexed msgHash,
        address indexed from,
        address indexed to,
        uint64 destChainId,
        address ctoken,
        address token,
        uint256 amount
    );
    event TokenReleased(
        bytes32 indexed msgHash, address indexed from, address ctoken, address token, uint256 amount
    );
    event TokenReceived(
        bytes32 indexed msgHash,
        address indexed from,
        address indexed to,
        uint64 srcChainId,
        address ctoken,
        address token,
        uint256 amount
    );

    error VAULT_BTOKEN_BLACKLISTED();
    error VAULT_CTOKEN_MISMATCH();
    error VAULT_INVALID_TOKEN();
    error VAULT_INVALID_AMOUNT();
    error VAULT_INVALID_NEW_BTOKEN();
    error VAULT_INVALID_TO();
    error VAULT_NOT_SAME_OWNER();

    function changeBridgedToken(
        CanonicalERC20 calldata ctoken,
        address btokenNew
    )
        external
        nonReentrant
        whenNotPaused
        onlyOwner
        returns (address rBtokenOld)
    {
        if (btokenNew == address(0) || bridgedToCanonical[btokenNew].addr != address(0)) {
            revert VAULT_INVALID_NEW_BTOKEN();
        }

        if (btokenBlacklist[btokenNew]) revert VAULT_BTOKEN_BLACKLISTED();

        if (IBridgedERC20(btokenNew).owner() != owner()) {
            revert VAULT_NOT_SAME_OWNER();
        }

        rBtokenOld = canonicalToBridged[ctoken.chainId][ctoken.addr];

        if (rBtokenOld != address(0)) {
            CanonicalERC20 memory _ctoken = bridgedToCanonical[rBtokenOld];

            // The ctoken must match the saved one.
            if (
                _ctoken.decimals != ctoken.decimals
                    || keccak256(bytes(_ctoken.symbol)) != keccak256(bytes(ctoken.symbol))
                    || keccak256(bytes(_ctoken.name)) != keccak256(bytes(ctoken.name))
            ) revert VAULT_CTOKEN_MISMATCH();

            delete bridgedToCanonical[rBtokenOld];
            btokenBlacklist[rBtokenOld] = true;

            // Start the migration
            IBridgedERC20(rBtokenOld).changeMigrationStatus(btokenNew, false);
            IBridgedERC20(btokenNew).changeMigrationStatus(rBtokenOld, true);
        }

        bridgedToCanonical[btokenNew] = ctoken;
        canonicalToBridged[ctoken.chainId][ctoken.addr] = btokenNew;

        emit BridgedTokenChanged({
            srcChainId: ctoken.chainId,
            ctoken: ctoken.addr,
            btokenOld: rBtokenOld,
            btokenNew: btokenNew,
            ctokenSymbol: ctoken.symbol,
            ctokenName: ctoken.name,
            ctokenDecimal: ctoken.decimals
        });
    }

    /// @notice Transfers ERC20 tokens to this vault and sends a message to the
    /// destination chain so the user can receive the same amount of tokens by
    /// invoking the message call.
    /// @param op Option for sending ERC20 tokens.
    /// @return rMessage The constructed message.
    function sendToken(BridgeTransferOp calldata op)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (IBridge.Message memory rMessage)
    {
        if (op.amount == 0) revert VAULT_INVALID_AMOUNT();
        if (op.token == address(0)) revert VAULT_INVALID_TOKEN();
        if (btokenBlacklist[op.token]) revert VAULT_BTOKEN_BLACKLISTED();

        uint256 _amount;
        IBridge.Message memory message;
        CanonicalERC20 memory ctoken;

        (message.data, ctoken, _amount) =
            _handleMessage({ user: msg.sender, token: op.token, amount: op.amount, to: op.to });

        message.destChainId = op.destChainId;
        message.srcOwner = msg.sender;
        message.destOwner = op.destOwner != address(0) ? op.destOwner : msg.sender;
        message.to = resolve(op.destChainId, name(), false);
        message.gasLimit = op.gasLimit;
        message.value = msg.value - op.fee;
        message.fee = op.fee;
        message.refundTo = op.refundTo;
        message.memo = op.memo;

        bytes32 msgHash;
        (msgHash, rMessage) =
            IBridge(resolve("bridge", false)).sendMessage{ value: msg.value }(message);

        emit TokenSent({
            msgHash: msgHash,
            from: rMessage.srcOwner,
            to: op.to,
            destChainId: op.destChainId,
            ctoken: ctoken.addr,
            token: op.token,
            amount: _amount
        });
    }

    /// @inheritdoc IMessageInvocable
    function onMessageInvocation(bytes calldata data) external payable nonReentrant whenNotPaused 
    // onlyFromBridge
    {
        (CanonicalERC20 memory ctoken, address from, address to, uint256 amount) =
            abi.decode(data, (CanonicalERC20, address, address, uint256));

        // `onlyFromBridge` checked in checkProcessMessageContext
        IBridge.Context memory ctx = checkProcessMessageContext();

        // Don't allow sending to disallowed addresses.
        // Don't send the tokens back to `from` because `from` is on the source chain.
        if (to == address(0) || to == address(this)) revert VAULT_INVALID_TO();

        // Transfer the ETH and the tokens to the `to` address
        address token = _transferTokens(ctoken, to, amount);
        to.sendEther(msg.value);

        emit TokenReceived({
            msgHash: ctx.msgHash,
            from: from,
            to: to,
            srcChainId: ctx.srcChainId,
            ctoken: ctoken.addr,
            token: token,
            amount: amount
        });
    }

    function onMessageRecalled(
        IBridge.Message calldata message,
        bytes32 msgHash
    )
        external
        payable
        override
        nonReentrant
        whenNotPaused
    // onlyFromBridge
    {
        // `onlyFromBridge` checked in checkRecallMessageContext
        checkRecallMessageContext();

        (bytes memory _data) = abi.decode(message.data[4:], (bytes));
        (CanonicalERC20 memory ctoken,,, uint256 amount) =
            abi.decode(_data, (CanonicalERC20, address, address, uint256));

        // Transfer the ETH and tokens back to the owner
        address token = _transferTokens(ctoken, message.srcOwner, amount);
        message.srcOwner.sendEther(message.value);

        emit TokenReleased({
            msgHash: msgHash,
            from: message.srcOwner,
            ctoken: ctoken.addr,
            token: token,
            amount: amount
        });
    }

    function name() public pure override returns (bytes32) {
        return "erc20_vault";
    }

    function _transferTokens(
        CanonicalERC20 memory ctoken,
        address to,
        uint256 amount
    )
        private
        returns (address rToken)
    {
        if (ctoken.chainId == block.chainid) {
            rToken = ctoken.addr;
            IERC20(rToken).safeTransfer(to, amount);
        } else {
            rToken = _getOrDeployBridgedToken(ctoken);
            IBridgedERC20(rToken).mint(to, amount);
        }
    }

    /// @dev Handles the message on the source chain and returns the encoded
    /// call on the destination call.
    /// @param user The user's address.
    /// @param token The token address.
    /// @param to To address.
    /// @param amount Amount to be sent.
    /// @return rMsgData Encoded message data.
    /// @return rCtoken The canonical token.
    /// @return rBalanceChange User token balance actual change after the token
    /// transfer. This value is calculated so we do not assume token balance
    /// change is the amount of token transfered away.
    function _handleMessage(
        address user,
        address token,
        address to,
        uint256 amount
    )
        private
        returns (bytes memory rMsgData, CanonicalERC20 memory rCtoken, uint256 rBalanceChange)
    {
        // If it's a bridged token
        if (bridgedToCanonical[token].addr != address(0)) {
            rCtoken = bridgedToCanonical[token];
            IBridgedERC20(token).burn(msg.sender, amount);
            rBalanceChange = amount;
        } else {
            // If it's a canonical token
            IERC20Metadata meta = IERC20Metadata(token);
            rCtoken = CanonicalERC20({
                chainId: uint64(block.chainid),
                addr: token,
                decimals: meta.decimals(),
                symbol: meta.symbol(),
                name: meta.name()
            });

            // Query the balance then query it again to get the actual amount of
            // token transferred into this address, this is more accurate than
            // simply using `amount` -- some contract may deduct a fee from the
            // transferred amount.
            IERC20 t = IERC20(token);
            uint256 _balance = t.balanceOf(address(this));
            t.safeTransferFrom({ from: msg.sender, to: address(this), value: amount });
            rBalanceChange = t.balanceOf(address(this)) - _balance;
        }

        rMsgData =
            abi.encodeCall(this.onMessageInvocation, abi.encode(rCtoken, user, to, rBalanceChange));
    }

    /// @dev Retrieve or deploy a bridged ERC20 token contract.
    /// @param ctoken CanonicalERC20 data.
    /// @return rBtoken Address of the bridged token contract.
    function _getOrDeployBridgedToken(CanonicalERC20 memory ctoken)
        private
        returns (address rBtoken)
    {
        rBtoken = canonicalToBridged[ctoken.chainId][ctoken.addr];

        if (rBtoken == address(0)) {
            rBtoken = _deployBridgedToken(ctoken);
        }
    }

    /// @dev Deploy a new BridgedERC20 contract and initialize it.
    /// This must be called before the first time a bridged token is sent to
    /// this chain.
    /// @param ctoken CanonicalERC20 data.
    /// @return rBtoken Address of the deployed bridged token contract.
    function _deployBridgedToken(CanonicalERC20 memory ctoken) private returns (address rBtoken) {
        bytes memory data = abi.encodeCall(
            BridgedERC20.init,
            (
                owner(),
                addressManager,
                ctoken.addr,
                ctoken.chainId,
                ctoken.decimals,
                ctoken.symbol,
                ctoken.name
            )
        );

        rBtoken = address(new ERC1967Proxy(resolve("bridged_erc20", false), data));
        bridgedToCanonical[rBtoken] = ctoken;
        canonicalToBridged[ctoken.chainId][ctoken.addr] = rBtoken;

        emit BridgedTokenDeployed({
            srcChainId: ctoken.chainId,
            ctoken: ctoken.addr,
            btoken: rBtoken,
            ctokenSymbol: ctoken.symbol,
            ctokenName: ctoken.name,
            ctokenDecimal: ctoken.decimals
        });
    }
}
