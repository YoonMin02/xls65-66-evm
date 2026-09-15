// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IXLS66BrokerBinding {
    function vault() external view returns (address);
    function owner() external view returns (address);
}

/// @notice An EVM port of the economically relevant XLS-65 Single Asset Vault paths.
/// @dev Asset amounts use the underlying ERC-20's smallest unit. Shares use `scale`
/// decimals, so a six-decimal USDC vault starts at one share unit per asset unit.
contract XLS65Vault is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error Unauthorized();
    error InvalidAmount();
    error InvalidConfiguration();
    error CapExceeded();
    error InsufficientLiquidity();
    error InsufficientShares();
    error PrecisionLoss();
    error TransferDisabled();
    error DepositorNotAllowed();
    error AccountingInvariant();
    error BrokerAlreadyBound();

    uint8 public immutable scale;
    IERC20 public immutable asset;
    address public immutable owner;
    bool public immutable isPrivate;
    bool public immutable sharesTransferable;

    bytes public data;
    uint256 public assetsTotal;
    uint256 public assetsAvailable;
    uint256 public lossUnrealized;
    uint256 public assetsMaximum;
    address public broker;

    mapping(address => bool) public allowedDepositor;

    event VaultDeposit(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event VaultWithdraw(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event VaultSet(uint256 assetsMaximum, bytes data);
    event BrokerBound(address indexed broker);
    event DepositorPermissionSet(address indexed depositor, bool allowed);
    event ProtocolLoan(
        address indexed accessor, address indexed borrower, uint256 principal, uint256 interestRecognized
    );
    event ProtocolRepayment(address indexed accessor, uint256 assetsReceived);
    event LoanImpairmentChanged(address indexed accessor, uint256 previousLoss, uint256 newLoss);
    event ProtocolDefault(address indexed accessor, uint256 defaultAmount, uint256 covered, uint256 realizedLoss);

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyBroker() {
        if (msg.sender != broker) revert Unauthorized();
        _;
    }

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        uint8 scale_,
        uint256 assetsMaximum_,
        bool private_,
        bool transferable_
    ) ERC20(name_, symbol_) {
        if (address(asset_) == address(0) || scale_ > 18) revert InvalidConfiguration();
        asset = asset_;
        scale = scale_;
        assetsMaximum = assetsMaximum_;
        isPrivate = private_;
        sharesTransferable = transferable_;
        owner = msg.sender;
        allowedDepositor[msg.sender] = true;
    }

    function decimals() public view override returns (uint8) {
        return scale;
    }

    function setVault(uint256 newMaximum, bytes calldata newData) external onlyOwner {
        if (newData.length > 256) revert InvalidConfiguration();
        if (newMaximum != 0 && newMaximum < assetsTotal) revert CapExceeded();
        assetsMaximum = newMaximum;
        data = newData;
        emit VaultSet(newMaximum, newData);
    }

    /// @notice Permanently binds this Vault to exactly one XLS-66 broker.
    /// @dev Binding is intentionally irreversible so depositors cannot be moved to
    /// a different risk policy after they have inspected the Vault/Broker pair.
    function bindBroker(address broker_) external onlyOwner {
        if (broker != address(0)) revert BrokerAlreadyBound();
        if (broker_ == address(0) || broker_.code.length == 0) revert InvalidConfiguration();

        try IXLS66BrokerBinding(broker_).vault() returns (address linkedVault) {
            if (linkedVault != address(this)) revert InvalidConfiguration();
        } catch {
            revert InvalidConfiguration();
        }
        try IXLS66BrokerBinding(broker_).owner() returns (address brokerOwner) {
            if (brokerOwner != owner) revert InvalidConfiguration();
        } catch {
            revert InvalidConfiguration();
        }

        broker = broker_;
        emit BrokerBound(broker_);
    }

    function setDepositorPermission(address depositor, bool allowed) external onlyOwner {
        allowedDepositor[depositor] = allowed;
        emit DepositorPermissionSet(depositor, allowed);
    }

    function effectiveAssets() public view returns (uint256) {
        return assetsTotal - lossUnrealized;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        if (totalSupply() == 0) return assets;
        return assets * totalSupply() / assetsTotal; // deposit price intentionally ignores paper loss
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (totalSupply() == 0) return 0;
        return shares * effectiveAssets() / totalSupply();
    }

    function maxRedeem(address account) external view returns (uint256) {
        uint256 shares = balanceOf(account);
        if (shares == 0 || totalSupply() == 0) return 0;
        uint256 pricedAssets = shares == totalSupply() ? shares * assetsTotal / totalSupply() : convertToAssets(shares);
        if (pricedAssets <= assetsAvailable) return shares;
        uint256 denominator = shares == totalSupply() ? assetsTotal : effectiveAssets();
        return assetsAvailable * totalSupply() / denominator;
    }

    function deposit(uint256 requestedAssets, address receiver) external nonReentrant returns (uint256 shares) {
        if (requestedAssets == 0 || receiver == address(0)) revert InvalidAmount();
        if (isPrivate && msg.sender != owner && !allowedDepositor[msg.sender]) revert DepositorNotAllowed();
        shares = convertToShares(requestedAssets);
        if (shares == 0) revert PrecisionLoss();

        // XLS-65 recalculates the asset debit after rounding shares down.
        uint256 assets = totalSupply() == 0 ? requestedAssets : _ceilDiv(shares * assetsTotal, totalSupply());
        if (assetsMaximum != 0 && assetsTotal + assets > assetsMaximum) revert CapExceeded();

        asset.safeTransferFrom(msg.sender, address(this), assets);
        assetsTotal += assets;
        assetsAvailable += assets;
        _mint(receiver, shares);
        _assertAccounting();
        emit VaultDeposit(msg.sender, receiver, assets, shares);
    }

    function redeem(uint256 shares, address receiver) public nonReentrant returns (uint256 assets) {
        if (shares == 0 || receiver == address(0)) revert InvalidAmount();
        if (balanceOf(msg.sender) < shares) revert InsufficientShares();
        // XLS-65 gives a sole shareholder the full value, without the paper-loss deduction.
        assets = shares == totalSupply() ? shares * assetsTotal / totalSupply() : convertToAssets(shares);
        if (assets > assetsAvailable) revert InsufficientLiquidity();
        _burn(msg.sender, shares);
        assetsTotal -= assets;
        assetsAvailable -= assets;
        if (lossUnrealized > assetsTotal) lossUnrealized = assetsTotal;
        asset.safeTransfer(receiver, assets);
        _assertAccounting();
        emit VaultWithdraw(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 requestedAssets, address receiver) external returns (uint256 assets, uint256 shares) {
        if (requestedAssets == 0 || effectiveAssets() == 0) revert InvalidAmount();
        // XLS-65 rounds the share quote to nearest, then derives the actual payout.
        uint256 numerator = requestedAssets * totalSupply();
        uint256 denominator = effectiveAssets();
        shares = (numerator + denominator / 2) / denominator;
        if (shares == 0) revert PrecisionLoss();
        assets = redeem(shares, receiver);
    }

    /// @dev Called by the permanently bound XLS-66 broker when principal leaves the vault.
    function protocolLoan(
        uint256 principal,
        uint256 netInterest,
        address borrower,
        address feeRecipient,
        uint256 originationFee
    ) external onlyBroker nonReentrant {
        if (principal == 0 || originationFee > principal) revert InvalidAmount();
        if (principal > assetsAvailable) revert InsufficientLiquidity();
        if (assetsMaximum != 0 && assetsTotal + netInterest > assetsMaximum) revert CapExceeded();
        assetsAvailable -= principal;
        assetsTotal += netInterest;
        asset.safeTransfer(borrower, principal - originationFee);
        if (originationFee != 0) asset.safeTransfer(feeRecipient, originationFee);
        _assertAccounting();
        emit ProtocolLoan(msg.sender, borrower, principal, netInterest);
    }

    function protocolRepayFrom(address payer, uint256 amount, uint256 valueIncrease, uint256 valueDecrease)
        external
        onlyBroker
        nonReentrant
    {
        if (amount == 0) revert InvalidAmount();
        if (valueIncrease != 0 && valueDecrease != 0) revert AccountingInvariant();
        asset.safeTransferFrom(payer, address(this), amount);
        assetsAvailable += amount;
        assetsTotal += valueIncrease;
        if (valueDecrease > assetsTotal) revert AccountingInvariant();
        assetsTotal -= valueDecrease;
        _assertAccounting();
        emit ProtocolRepayment(msg.sender, amount);
    }

    function setLoanImpairment(uint256 previousLoss, uint256 newLoss) external onlyBroker {
        if (lossUnrealized < previousLoss) revert AccountingInvariant();
        uint256 aggregate = lossUnrealized - previousLoss + newLoss;
        if (aggregate > assetsTotal - assetsAvailable) revert AccountingInvariant();
        lossUnrealized = aggregate;
        emit LoanImpairmentChanged(msg.sender, previousLoss, newLoss);
    }

    function protocolDefault(uint256 defaultAmount, uint256 covered, uint256 impairedAmount)
        external
        onlyBroker
        nonReentrant
    {
        if (covered > defaultAmount || lossUnrealized < impairedAmount) revert AccountingInvariant();
        uint256 realizedLoss = defaultAmount - covered;
        if (realizedLoss > assetsTotal) revert AccountingInvariant();
        if (covered != 0) asset.safeTransferFrom(msg.sender, address(this), covered);
        assetsTotal -= realizedLoss;
        assetsAvailable += covered;
        lossUnrealized -= impairedAmount;
        _assertAccounting();
        emit ProtocolDefault(msg.sender, defaultAmount, covered, realizedLoss);
    }

    function _update(address from, address to, uint256 amount) internal override {
        bool regularTransfer = from != address(0) && to != address(0);
        if (regularTransfer && !sharesTransferable) revert TransferDisabled();
        if (regularTransfer && isPrivate && !allowedDepositor[to] && to != owner) revert DepositorNotAllowed();
        super._update(from, to, amount);
    }

    function _assertAccounting() internal view {
        if (lossUnrealized > assetsTotal - assetsAvailable) revert AccountingInvariant();
        if (asset.balanceOf(address(this)) < assetsAvailable) revert AccountingInvariant();
    }

    function _ceilDiv(uint256 x, uint256 y) internal pure returns (uint256) {
        return x == 0 ? 0 : (x - 1) / y + 1;
    }
}
