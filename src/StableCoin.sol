// SPDX-License-Identifier: AEL
pragma solidity ^0.8.0;

import "./tokens/Tokeon.sol";
import "./interfaces/IPyth.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract StableCoinReactor is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;
    
    // Tokens
    Tokeon public immutable neutron;    // ERC20 for the stable token
    Tokeon public immutable proton;     // ERC20 for the volatile token
    IERC20 public immutable base;       // ERC20 token used as the reserve asset

    string public vaultName;
    
    // Oracle integration
    IPyth public immutable pyth;              // Pyth oracle contract
    bytes32 public immutable priceId;         // Pyth price feed ID for the stable token target
    uint256 public immutable maxPriceAge;     // Maximum age for price data (seconds)
    
    // Critical ratio and stability
    uint256 public constant criticalRatio = 0.8e18; // Fixed 80% critical reserve ratio (q*)
    uint256 public constant RATIO_PRECISION = 1e18; // Precision for ratio calculations
    
    // Treasury and fees
    address public immutable treasury;         // address of the treasury
    uint256 public immutable fissionFee;      // fee paid when fission is performed (1e18 scale)
    uint256 public immutable fusionFee;       // fee paid when fusion is performed (1e18 scale)
    
    // Events
    event Fission(address indexed from, address indexed to, uint256 baseIn, uint256 neutronOut, uint256 protonOut, uint256 feeToTreasury);
    event Fusion(address indexed from, address indexed to, uint256 neutronBurn, uint256 protonBurn, uint256 baseOut, uint256 feeToTreasury);
    event CriticalRatioBreached(uint256 currentRatio, uint256 criticalRatio);
    event PriceUpdated(bytes32 indexed priceId, int64 price, uint256 timestamp);
    
    constructor(
        string memory _vaultName,
        address _base,
        address _pyth,
        bytes32 _priceId,
        uint256 _maxPriceAge,
        string memory _neutronName, 
        string memory _neutronSymbol,
        string memory _protonName, 
        string memory _protonSymbol,
        address _treasury, 
        uint256 _fissionFee, 
        uint256 _fusionFee
    ) {
        vaultName = _vaultName;
        base = IERC20(_base);
        pyth = IPyth(_pyth);
        priceId = _priceId;
        maxPriceAge = _maxPriceAge;
        
        neutron = new Tokeon(_neutronName, _neutronSymbol, address(this));
        proton = new Tokeon(_protonName, _protonSymbol, address(this));
        
        treasury = _treasury;
        fissionFee = _fissionFee;
        fusionFee = _fusionFee;
        
        require(_fissionFee < 1e18, "fissionFee >= 100%");
        require(_fusionFee < 1e18, "fusionFee >= 100%");
        require(_pyth != address(0), "Invalid Pyth address");
        require(_maxPriceAge > 0, "Invalid max price age");
    }
    
    function reserve() public view returns (uint256) {
        return base.balanceOf(address(this)); // base = IERC20 reserve
    }
    
    /**
     * @dev Calculate current reserve ratio: R / (neutron_supply * target_price + proton_supply * proton_price)
     * This represents how well-collateralized the system is
     */
    function reserveRatio() public view returns (uint256) {
        uint256 R = reserve();
        if (R == 0) return 0;
        
        uint256 neutronSupply_ = neutron.totalSupply();
        uint256 protonSupply_ = proton.totalSupply();
        
        if (neutronSupply_ == 0 && protonSupply_ == 0) return type(uint256).max;
        
        // Get target price for neutron from Pyth oracle
        uint256 targetPrice = getNeutronTargetPrice();
        
        // Calculate proton price based on current reserves and supply
        uint256 protonPrice = protonSupply_ > 0 ? (R * RATIO_PRECISION) / protonSupply_ : RATIO_PRECISION;
        
        // Total value = neutron_supply * target_price + proton_supply * proton_price
        uint256 totalValue = (neutronSupply_ * targetPrice / RATIO_PRECISION) + (protonSupply_ * protonPrice / RATIO_PRECISION);
        
        return totalValue > 0 ? (R * RATIO_PRECISION) / totalValue : 0;
    }
    
    /**
     * @dev Get the target price for neutron token from Pyth oracle
     */
    function getNeutronTargetPrice() public view returns (uint256) {
        Price memory price = pyth.getPriceNoOlderThan(priceId, maxPriceAge);
        require(price.price > 0, "Invalid price from oracle");
        
        // Convert price to 18 decimal precision
        if (price.expo >= 0) {
            return uint256(uint64(price.price)) * RATIO_PRECISION * (10 ** uint32(price.expo));
        } else {
            return uint256(uint64(price.price)) * RATIO_PRECISION / (10 ** uint32(-price.expo));
        }
    }
    
    /**
     * @dev Check if system is above critical ratio
     */
    function isAboveCriticalRatio() public view returns (bool) {
        return reserveRatio() >= criticalRatio;
    }

    /* -------------------------- Table-2: FISSION -------------------------- */
    function fission(uint256 m, address to) external nonReentrant {
        require(m > 0, "amount=0");

        uint256 R0 = reserve();                         // R BEFORE this trade
        base.safeTransferFrom(msg.sender, address(this), m);

        // fee -> treasury; net used to mint
        uint256 fee = Math.mulDiv(m, fissionFee, 1e18); // Φ↓ (1e18 scale)
        if (fee > 0) base.safeTransfer(treasury, fee);
        uint256 net = m - fee;                          // m(1-Φ↓)

        uint256 S_n = neutron.totalSupply();            // S◦
        uint256 S_p = proton.totalSupply();             // S•

        uint256 nOut; uint256 pOut;

        if (R0 == 0 || S_n == 0 || S_p == 0) {
            // Bootstrap: mint equally (no prior ratio to preserve).
            // Assumes 18-dec neutron/proton. Scale base decimals to 18.
            uint8 bDec = IERC20Metadata(address(base)).decimals();
            uint256 scale = 10 ** (18 - bDec);
            nOut = net * scale;
            pOut = net * scale;
        } else {
            // Table-2: net * S / R_before
            nOut = Math.mulDiv(net, S_n, R0);
            pOut = Math.mulDiv(net, S_p, R0);
        }

        neutron.mint(to, nOut);
        proton.mint(to,  pOut);

        emit Fission(msg.sender, to, m, nOut, pOut, fee);
    }

    /* -------------------------- Table-2: FUSION --------------------------- */
    /* Withdraw exactly m base (contract computes burns), pays out m(1-Φ↑). */
    function fusion(uint256 m, address to) external nonReentrant {
        require(m > 0, "amount=0");

        uint256 R  = reserve();                         // current R
        require(R > 0, "R=0");

        uint256 S_n = neutron.totalSupply();            // S◦
        uint256 S_p = proton.totalSupply();             // S•
        require(S_n > 0 && S_p > 0, "empty S");

        // Table-2: burns = m * S / R
        uint256 nBurn = Math.mulDiv(m, S_n, R);
        uint256 pBurn = Math.mulDiv(m, S_p, R);

        neutron.burn(msg.sender, nBurn);
        proton .burn(msg.sender, pBurn);

        // Pay out m(1-Φ↑)
        uint256 fee = Math.mulDiv(m, fusionFee, 1e18);  // Φ↑ (1e18 scale)
        uint256 net = m - fee;

        base.safeTransfer(to, net);
        if (fee > 0) base.safeTransfer(treasury, fee);

        emit Fusion(msg.sender, to, nBurn, pBurn, net, fee);
    }
    
    /**
     * @dev Update Pyth price feeds before operations
     * @param updateData Array of price update data from Pyth
     */
    function updatePriceFeeds(bytes[] calldata updateData) external payable {
        uint256 fee = pyth.getUpdateFee(updateData);
        require(msg.value >= fee, "Insufficient fee for price update");
        
        pyth.updatePriceFeeds{value: fee}(updateData);
        
        // Get updated price for event
        Price memory price = pyth.getPriceUnsafe(priceId);
        emit PriceUpdated(priceId, price.price, price.publishTime);
        
        // Refund excess fee
        if (msg.value > fee) {
            payable(msg.sender).transfer(msg.value - fee);
        }
    }
    
    // Getter functions for convenience
    function neutronSupply() external view returns (uint256) {
        return neutron.totalSupply();
    }
    
    function protonSupply() external view returns (uint256) {
        return proton.totalSupply();
    }
    
    function baseDecimals() external view returns (uint8) {
        return IERC20Metadata(address(base)).decimals();
    }
    
    // Emergency function to check system health
    function systemHealth() external view returns (
        uint256 currentReserveRatio,
        uint256 criticalRatioThreshold,
        bool isHealthy,
        uint256 neutronPrice,
        uint256 protonPrice
    ) {
        currentReserveRatio = reserveRatio();
        criticalRatioThreshold = criticalRatio;
        isHealthy = currentReserveRatio >= criticalRatio;
        neutronPrice = getNeutronTargetPrice();
        
        uint256 R = reserve();
        uint256 protonSupply_ = proton.totalSupply();
        protonPrice = protonSupply_ > 0 ? (R * RATIO_PRECISION) / protonSupply_ : RATIO_PRECISION;
    }
}