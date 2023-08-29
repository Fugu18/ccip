// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {IBurnMintERC20} from "../../../shared/token/ERC20/IBurnMintERC20.sol";
import {ITokenMessenger} from "./ITokenMessenger.sol";
import {IMessageReceiver} from "./IMessageReceiver.sol";

import {TokenPool} from "../TokenPool.sol";

/// @notice This pool mints and burns USDC tokens through the Cross Chain Transfer
/// Protocol (CCTP).
contract USDCTokenPool is TokenPool {
  event DomainsSet(DomainUpdate[]);
  event ConfigSet(USDCConfig);

  error UnknownDomain(uint64 domain);
  error UnlockingUSDCFailed();
  error InvalidConfig();
  error InvalidNonce(uint64 expected, uint64 got);
  error InvalidSender(bytes32 expected, bytes32 got);
  error InvalidReceiver(bytes32 expected, bytes32 got);
  error InvalidDomain(uint32 got);

  // This data is supplied from offchain and contains everything needed
  // to receive the USDC tokens.
  struct MessageAndAttestation {
    bytes message;
    bytes attestation;
  }

  // A domain is a USDC representation of a chain.
  struct DomainUpdate {
    bytes32 allowedCaller; //       Address allowed to mint on the domain
    uint32 domainIdentifier; // --┐ Unique domain ID
    uint64 destChainSelector; //  | The destination chain for this domain
    bool enabled; // -------------┘ Whether the domain is enabled
  }

  // Contains the contracts for sending and receiving USDC tokens
  struct USDCConfig {
    uint32 version; // ----------┐ CCTP internal version
    address tokenMessenger; // --┘ Contract to burn tokens
    address messageTransmitter; // Contract to mint tokens
  }

  uint32 public immutable i_localDomainIdentifier;

  // The local USDC config
  USDCConfig private s_config;

  // The unique USDC pool flag to signal through EIP 165 that this is a USDC token pool.
  bytes4 private constant USDC_INTERFACE_ID = bytes4(keccak256("USDC"));

  // A domain is a USDC representation of a chain.
  struct Domain {
    bytes32 allowedCaller; //      Address allowed to mint on the domain
    uint32 domainIdentifier; // -┐ Unique domain ID
    bool enabled; // ------------┘ Whether the domain is enabled
  }

  // A mapping of CCIP chain identifiers to destination domains
  mapping(uint64 chainSelector => Domain CCTPDomain) private s_chainToDomain;

  constructor(
    USDCConfig memory config,
    IBurnMintERC20 token,
    address[] memory allowlist,
    address armProxy,
    uint32 localDomainIdentifier
  ) TokenPool(token, allowlist, armProxy) {
    _setConfig(config);
    i_localDomainIdentifier = localDomainIdentifier;
  }

  /// @notice returns the USDC interface flag used for EIP165 identification.
  function getUSDCInterfaceId() public pure returns (bytes4) {
    return USDC_INTERFACE_ID;
  }

  // @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
    return interfaceId == USDC_INTERFACE_ID || super.supportsInterface(interfaceId);
  }

  /// @notice Burn the token in the pool
  /// @dev Burn is not rate limited at per-pool level. Burn does not contribute to honey pot risk.
  /// Benefits of rate limiting here does not justify the extra gas cost.
  /// @param amount Amount to burn
  /// @dev emits ITokenMessenger.DepositForBurn
  function lockOrBurn(
    address originalSender,
    bytes calldata destinationReceiver,
    uint256 amount,
    uint64 destChainSelector,
    bytes calldata
  ) external override onlyOnRamp checkAllowList(originalSender) returns (bytes memory) {
    Domain memory domain = s_chainToDomain[destChainSelector];
    if (!domain.enabled) revert UnknownDomain(destChainSelector);
    _consumeOnRampRateLimit(amount);
    bytes32 receiver = bytes32(destinationReceiver[0:32]);
    uint64 nonce = ITokenMessenger(s_config.tokenMessenger).depositForBurnWithCaller(
      amount,
      domain.domainIdentifier,
      receiver,
      address(i_token),
      domain.allowedCaller
    );
    emit Burned(msg.sender, amount);
    return abi.encode(nonce);
  }

  /// @notice Mint tokens from the pool to the recipient
  /// @param receiver Recipient address
  /// @param amount Amount to mint
  function releaseOrMint(
    bytes calldata originalSender,
    address receiver,
    uint256 amount,
    uint64,
    bytes memory extraData
  ) external override onlyOffRamp {
    _consumeOffRampRateLimit(amount);
    (bytes memory offchainTokenData, bytes memory nonceBytes) = abi.decode(extraData, (bytes, bytes));
    MessageAndAttestation memory msgAndAttestation = abi.decode(offchainTokenData, (MessageAndAttestation));

    _validateMessage(
      msgAndAttestation.message,
      abi.decode(nonceBytes, (uint64)),
      bytes32(originalSender[0:32]),
      bytes32(uint256(uint160(receiver)))
    );

    if (
      !IMessageReceiver(s_config.messageTransmitter).receiveMessage(
        msgAndAttestation.message,
        msgAndAttestation.attestation
      )
    ) revert UnlockingUSDCFailed();
    emit Minted(msg.sender, receiver, amount);
  }

  function _validateMessage(
    bytes memory usdcMessage,
    uint64 expectedNonce,
    bytes32 expectedSender,
    bytes32 expectedReceiver
  ) internal view {
    uint32 destinationDomain;
    uint64 nonce;
    bytes32 sender;
    bytes32 receiver;

    // solhint-disable-next-line no-inline-assembly
    assembly {
      destinationDomain := mload(add(usdcMessage, 12)) // 8 + 4 = 12
      nonce := mload(add(usdcMessage, 20)) // 12 + 8 = 20
      sender := mload(add(usdcMessage, 52)) // 20 + 32 = 52
      receiver := mload(add(usdcMessage, 84)) // 52 + 32 = 84
    }

    if (i_localDomainIdentifier != destinationDomain) revert InvalidDomain(destinationDomain);
    if (expectedNonce != nonce) revert InvalidNonce(expectedNonce, nonce);
    if (expectedSender != sender) revert InvalidSender(expectedSender, sender);
    if (expectedReceiver != receiver) revert InvalidReceiver(expectedReceiver, receiver);
  }

  // ================================================================
  // |                           Config                             |
  // ================================================================

  /// @notice Gets the current config
  function getConfig() external view returns (USDCConfig memory) {
    return s_config;
  }

  /// @notice Sets the config
  function setConfig(USDCConfig memory config) external onlyOwner {
    _setConfig(config);
  }

  /// @notice Sets the config
  function _setConfig(USDCConfig memory config) internal {
    if (config.messageTransmitter == address(0) || config.tokenMessenger == address(0)) revert InvalidConfig();
    // Revoke approval for previous token messenger
    if (s_config.tokenMessenger != address(0)) i_token.approve(s_config.tokenMessenger, 0);
    // Approve new token messenger
    i_token.approve(config.tokenMessenger, type(uint256).max);
    s_config = config;
    emit ConfigSet(config);
  }

  /// @notice Gets the CCTP domain for a given CCIP chain selector.
  function getDomain(uint64 chainSelector) external view returns (Domain memory) {
    return s_chainToDomain[chainSelector];
  }

  /// @notice Sets the CCTP domain for a CCIP chain selector.
  function setDomains(DomainUpdate[] calldata domains) external onlyOwner {
    for (uint256 i = 0; i < domains.length; ++i) {
      DomainUpdate memory domain = domains[i];
      s_chainToDomain[domain.destChainSelector] = Domain({
        domainIdentifier: domain.domainIdentifier,
        allowedCaller: domain.allowedCaller,
        enabled: domain.enabled
      });
    }
    emit DomainsSet(domains);
  }
}
