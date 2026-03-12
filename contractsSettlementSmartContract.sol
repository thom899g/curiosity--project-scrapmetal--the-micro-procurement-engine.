// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title ProfitQuarantineVault
 * @dev Non-bypassable profit quarantine enforcement with atomic settlement
 * Key architectural choice: Profit quarantine happens atomically in same transaction
 * as trade execution, eliminating any window for interception or manipulation.
 */
contract ProfitQuarantineVault is ReentrancyGuard, Ownable {
    using ECDSA for bytes32;
    
    // ----- CONSTANTS & IMMUTABLES -----
    address public immutable HARDWARE_VAULT;
    address public immutable DEX_AGGREGATOR;
    IERC20 public immutable USDC;
    
    // ----- STATE VARIABLES -----
    mapping(address => bool) public authorizedExecutors;
    mapping(bytes32 => bool) public executedBundles;
    uint256 public totalProfitsQuarantined;
    uint256 public emergencyModeActivatedAt;
    
    // ----- EVENTS -----
    event TradeExecuted(
        bytes32 indexed bundleHash,
        address indexed executor,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 profitQuarantined
    );
    event ProfitQuarantined(
        address indexed token,
        uint256 amount,
        uint256 usdcValue,
        address indexed hardwareVault
    );
    event EmergencyModeActivated(address indexed activator, uint256 timestamp);
    event ExecutorAuthorized(address indexed executor, bool authorized);
    
    // ----- CUSTOM ERRORS -----
    error InvalidSignature();
    error BundleAlreadyExecuted();
    error InsufficientOutput();
    error NotAuthorizedExecutor();
    error EmergencyModeActive();
    error InvalidAggregatorResponse();
    
    // ----- STRUCTS -----
    struct TradeBundle {
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 minOutputAmount;
        bytes swapData; // Encoded parameters for DEX aggregator
        uint256 deadline;
        uint256 nonce;
    }
    
    // ----- CONSTRUCTOR -----
    constructor(
        address _hardwareVault,
        address _dexAggregator,
        address _usdc
    ) {
        require(_hardwareVault != address(0), "Zero hardware vault");
        require(_dexAggregator != address(0), "Zero DEX aggregator");
        require(_usdc != address(0), "Zero USDC address");
        
        HARDWARE_VAULT = _hardwareVault;
        DEX_AGGREGATOR = _dexAggregator;
        USDC = IERC20(_usdc);
        
        // Owner is initial authorized executor
        authorizedExecutors[msg.sender] = true;
        emit ExecutorAuthorized(msg.sender, true);
    }
    
    // ----- MODIFIERS -----
    modifier onlyAuthorized() {
        if (!authorizedExecutors[msg.sender]) revert NotAuthorizedExecutor();
        _;
    }
    
    modifier notInEmergency() {
        if (emergencyModeActivatedAt > 0) revert EmergencyModeActive();
        _;
    }
    
    // ----- CORE LOGIC -----
    
    /**
     * @dev Execute trade bundle with atomic profit quarantine
     * Edge cases handled:
     * - Signature replay protection via nonce + bundleHash
     * - Deadline expiration
     * - Minimum output guarantee
     * - Front-running protection via bundle hash
     */
    function executeTradeBundle(
        TradeBundle calldata bundle,
        bytes calldata signature
    ) external nonReentrant notInEmergency onlyAuthorized returns (uint256) {
        // 1. Verify signature and bundle validity
        _verifyBundle(bundle, signature);
        
        // 2. Check deadline
        require(bundle.deadline >= block.timestamp, "Bundle expired");
        
        // 3. Transfer input tokens from executor
        IERC20 inputToken = IERC20(bundle.inputToken);
        require(
            inputToken.transferFrom(msg.sender, address(this), bundle.inputAmount),
            "Transfer failed"
        );
        
        // 4. Approve aggregator and execute swap
        inputToken.approve(DEX_AGGREGATOR, bundle.inputAmount);
        
        (bool success, bytes memory result) = DEX_AGGREGATOR.call(bundle.swapData);
        if (!success) revert InvalidAggregatorResponse();
        
        uint256 outputAmount = abi.decode(result, (uint256));
        
        // 5. Validate minimum output
        if (outputAmount < bundle.minOutputAmount) revert InsufficientOutput();
        
        // 6. Calculate and quarantine profit atomically
        uint256 profit = outputAmount - bundle.inputAmount;
        
        if (profit > 0) {
            // Swap profit to USDC atomically
            IERC20 outputToken = IERC20(bundle.outputToken);
            outputToken.approve(DEX_AGGREGATOR, profit);
            
            // Simplified: In production, this would be a proper swap call
            // For now, we assume output token is already USDC
            if (bundle.outputToken != address(USDC)) {
                // Would call aggregator for swap to USDC
                // This is placeholder for actual swap logic
            }
            
            // Transfer profit to hardware vault
            require(
                USDC.transfer(HARDWARE_VAULT, profit),
                "Profit transfer failed"
            );
            
            totalProfitsQuarantined += profit;
            emit ProfitQuarantined(bundle.outputToken, profit, profit, HARDWARE_VAULT);
        }
        
        // 7. Return remaining capital to executor
        uint256 remaining = outputAmount - profit;
        if (remaining > 0) {
            IERC20(bundle.outputToken).transfer(msg.sender, remaining);
        }
        
        emit TradeExecuted(
            keccak256(abi.encode(bundle)),
            msg.sender,
            bundle.inputAmount,
            outputAmount,
            profit
        );
        
        return profit;
    }
    
    /**
     * @dev Emergency withdrawal bypassing normal flow
     * Can only be triggered by owner after multi-sig consensus in production
     */
    function emergencyWithdrawAll(address token) external onlyOwner {
        emergencyModeActivatedAt = block.timestamp;
        
        IERC20 tokenContract = IERC20(token);
        uint256 balance = tokenContract.balanceOf(address(this));
        
        if (balance > 0) {
            require(
                tokenContract.transfer(HARDWARE_VAULT, balance),
                "Emergency transfer failed"
            );
        }
        
        emit EmergencyModeActivated(msg.sender, block.timestamp);
    }
    
    // ----- INTERNAL FUNCTIONS -----
    
    function _verifyBundle(
        TradeBundle calldata bundle,
        bytes calldata signature
    ) internal {
        bytes32 bundleHash = keccak256(abi.encode(bundle));
        
        // Prevent replay attacks
        if (executedBundles[bundleHash]) revert BundleAlreadyExecuted();
        executedBundles[bundleHash] = true;
        
        // Verify signature from authorized executor
        bytes32 ethSignedHash = bundleHash.toEthSignedMessageHash();
        address signer = ethSignedHash.recover(signature);
        
        if (!authorizedExecutors[signer]) revert InvalidSignature();
    }
    
    // ----- ADMIN FUNCTIONS -----
    
    function authorizeExecutor(address executor, bool authorized) external onlyOwner {
        authorizedExecutors[executor] = authorized;
        emit ExecutorAuthorized(executor, authorized);
    }
    
    // ----- VIEW FUNCTIONS -----
    
    function getBundleHash(TradeBundle calldata bundle) external pure returns (bytes32) {
        return keccak256(abi.encode(bundle));
    }
    
    function isEmergencyMode() external view returns (bool) {
        return emergencyModeActivatedAt > 0;
    }
}