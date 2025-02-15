// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "../bridge/IBridge.sol";
import "../libs/LibAddress.sol";
import "./BaseNFTVault.sol";
import "./BridgedERC721.sol";

/// @title ERC721Vault
/// @notice This vault holds all ERC721 tokens that users have deposited. It also manages
/// the mapping between canonical tokens and their bridged tokens.
/// @dev Labeled in AddressResolver as "erc721_vault".
/// @custom:security-contact security@taiko.xyz
contract ERC721Vault is BaseNFTVault, IERC721Receiver {
    using LibAddress for address;

    uint256[50] private __gap;

    /// @notice Transfers ERC721 tokens to this vault and sends a message to the
    /// destination chain so the user can receive the same (bridged) tokens
    /// by invoking the message call.
    /// @param _op Option for sending the ERC721 token.
    /// @return message_ The constructed message.
    function sendToken(BridgeTransferOp memory _op)
        external
        payable
        nonReentrant
        whenNotPaused
        withValidOperation(_op)
        returns (IBridge.Message memory message_)
    {
        for (uint256 i; i < _op.tokenIds.length; ++i) {
            if (_op.amounts[i] != 0) revert VAULT_INVALID_AMOUNT();
        }

        if (!_op.token.supportsInterface(ERC721_INTERFACE_ID)) {
            revert VAULT_INTERFACE_NOT_SUPPORTED();
        }

        (bytes memory data, CanonicalNFT memory ctoken) = _handleMessage(msg.sender, _op);

        IBridge.Message memory message;
        message.destChainId = _op.destChainId;
        message.data = data;
        message.srcOwner = msg.sender;
        message.destOwner = _op.destOwner != address(0) ? _op.destOwner : msg.sender;
        message.to = resolve(message.destChainId, name(), false);
        message.gasLimit = _op.gasLimit;
        message.value = msg.value - _op.fee;
        message.fee = _op.fee;
        message.refundTo = _op.refundTo;
        message.memo = _op.memo;

        bytes32 msgHash;
        (msgHash, message_) =
            IBridge(resolve("bridge", false)).sendMessage{ value: msg.value }(message);

        emit TokenSent({
            msgHash: msgHash,
            from: message_.srcOwner,
            to: _op.to,
            destChainId: message_.destChainId,
            ctoken: ctoken.addr,
            token: _op.token,
            tokenIds: _op.tokenIds,
            amounts: _op.amounts
        });
    }

    /// @inheritdoc IMessageInvocable
    function onMessageInvocation(bytes calldata _data)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        (CanonicalNFT memory ctoken, address from, address to, uint256[] memory tokenIds) =
            abi.decode(_data, (CanonicalNFT, address, address, uint256[]));

        // `onlyFromBridge` checked in checkProcessMessageContext
        IBridge.Context memory ctx = checkProcessMessageContext();

        // Don't allow sending to disallowed addresses.
        // Don't send the tokens back to `from` because `from` is on the source chain.
        if (to == address(0) || to == address(this)) revert VAULT_INVALID_TO();

        // Transfer the ETH and the tokens to the `to` address
        address token = _transferTokens(ctoken, to, tokenIds);
        to.sendEther(msg.value);

        emit TokenReceived({
            msgHash: ctx.msgHash,
            from: from,
            to: to,
            srcChainId: ctx.srcChainId,
            ctoken: ctoken.addr,
            token: token,
            tokenIds: tokenIds,
            amounts: new uint256[](tokenIds.length)
        });
    }

    /// @inheritdoc IRecallableSender
    function onMessageRecalled(
        IBridge.Message calldata _message,
        bytes32 _msgHash
    )
        external
        payable
        override
        nonReentrant
        whenNotPaused
    {
        // `onlyFromBridge` checked in checkRecallMessageContext
        checkRecallMessageContext();

        (bytes memory data) = abi.decode(_message.data[4:], (bytes));
        (CanonicalNFT memory ctoken,,, uint256[] memory tokenIds) =
            abi.decode(data, (CanonicalNFT, address, address, uint256[]));

        // Transfer the ETH and tokens back to the owner
        address token = _transferTokens(ctoken, _message.srcOwner, tokenIds);
        _message.srcOwner.sendEther(_message.value);

        emit TokenReleased({
            msgHash: _msgHash,
            from: _message.srcOwner,
            ctoken: ctoken.addr,
            token: token,
            tokenIds: tokenIds,
            amounts: new uint256[](tokenIds.length)
        });
    }

    /// @inheritdoc IERC721Receiver
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    )
        external
        pure
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @inheritdoc BaseVault
    function name() public pure override returns (bytes32) {
        return "erc721_vault";
    }

    function _transferTokens(
        CanonicalNFT memory _ctoken,
        address _to,
        uint256[] memory _tokenIds
    )
        private
        returns (address token_)
    {
        if (_ctoken.chainId == block.chainid) {
            token_ = _ctoken.addr;
            for (uint256 i; i < _tokenIds.length; ++i) {
                IERC721(token_).safeTransferFrom(address(this), _to, _tokenIds[i]);
            }
        } else {
            token_ = _getOrDeployBridgedToken(_ctoken);
            for (uint256 i; i < _tokenIds.length; ++i) {
                BridgedERC721(token_).mint(_to, _tokenIds[i]);
            }
        }
    }

    /// @dev Handles the message on the source chain and returns the encoded
    /// call on the destination call.
    /// @param _user The user's address.
    /// @param _op BridgeTransferOp data.
    /// @return msgData_ Encoded message data.
    /// @return ctoken_ The canonical token.
    function _handleMessage(
        address _user,
        BridgeTransferOp memory _op
    )
        private
        returns (bytes memory msgData_, CanonicalNFT memory ctoken_)
    {
        unchecked {
            if (bridgedToCanonical[_op.token].addr != address(0)) {
                ctoken_ = bridgedToCanonical[_op.token];
                for (uint256 i; i < _op.tokenIds.length; ++i) {
                    BridgedERC721(_op.token).burn(_user, _op.tokenIds[i]);
                }
            } else {
                ERC721Upgradeable t = ERC721Upgradeable(_op.token);

                ctoken_ = CanonicalNFT({
                    chainId: uint64(block.chainid),
                    addr: _op.token,
                    symbol: t.symbol(),
                    name: t.name()
                });

                for (uint256 i; i < _op.tokenIds.length; ++i) {
                    t.safeTransferFrom(_user, address(this), _op.tokenIds[i]);
                }
            }
        }

        msgData_ = abi.encodeCall(
            this.onMessageInvocation, abi.encode(ctoken_, _user, _op.to, _op.tokenIds)
        );
    }

    /// @dev Retrieve or deploy a bridged ERC721 token contract.
    /// @param _ctoken CanonicalNFT data.
    /// @return btoken_ Address of the bridged token contract.
    function _getOrDeployBridgedToken(CanonicalNFT memory _ctoken)
        private
        returns (address btoken_)
    {
        btoken_ = canonicalToBridged[_ctoken.chainId][_ctoken.addr];

        if (btoken_ == address(0)) {
            btoken_ = _deployBridgedToken(_ctoken);
        }
    }

    /// @dev Deploy a new BridgedNFT contract and initialize it.
    /// This must be called before the first time a bridged token is sent to
    /// this chain.
    /// @param _ctoken CanonicalNFT data.
    /// @return btoken_ Address of the deployed bridged token contract.
    function _deployBridgedToken(CanonicalNFT memory _ctoken) private returns (address btoken_) {
        bytes memory data = abi.encodeCall(
            BridgedERC721.init,
            (owner(), addressManager, _ctoken.addr, _ctoken.chainId, _ctoken.symbol, _ctoken.name)
        );

        btoken_ = address(new ERC1967Proxy(resolve("bridged_erc721", false), data));
        bridgedToCanonical[btoken_] = _ctoken;
        canonicalToBridged[_ctoken.chainId][_ctoken.addr] = btoken_;

        emit BridgedTokenDeployed({
            chainId: _ctoken.chainId,
            ctoken: _ctoken.addr,
            btoken: btoken_,
            ctokenSymbol: _ctoken.symbol,
            ctokenName: _ctoken.name
        });
    }
}
