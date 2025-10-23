// SPDX-License-Identifier: AEL
pragma solidity ^0.8.20;

import "./tokens/Tokeon.sol";
import "./interfaces/IPyth.sol";
import {Price} from "./interfaces/IPyth.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol"; 
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract StableCoinReactor is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant WAD = 1e18;
    uint256 public constant PEG_PeggedAsset_WAD = 1e18; // 1 PeggedAsset per neutron target (can be changed to non-PeggedAsset peg by scaling externals)
    
    Tokeon public immutable neutron;   // stable token (peg)
    Tokeon public immutable proton;    // volatile token
    IERC20 public immutable base;      // reserve PeggedAsset (ERC20) 

    string public vaultName;

    IPyth   public immutable pyth;     // Pyth oracle
    bytes32 public immutable priceId;  // Base/PeggedAsset price feed ID (NOTE: now BASE price feed)

    address public immutable treasury;
    uint256 public immutable fissionFee; // on fission  (WAD)
    uint256 public immutable fusionFee;  // on fusion   (WAD)

    // Target Reserve Ratio r = R* (e.g., 4e18 means 400%)
    uint256 public immutable targetReserveRatio;

    // φβ = min(1, phi0 + phi1 * max(±Vbar,0)/R)
    uint256 public betaPhi0;            // WAD
    uint256 public betaPhi1;            // WAD
    uint256 public decayPerSecondWAD;   // δ in WAD, e.g. 0.9995e18
    int256  private decayedVolumeBase;  // \bar V in BASE units (WAD-scaled)
    uint256 private lastDecayTs;        // last ledger update

    event Fission(
        address indexed from,
        address indexed to,
        uint256 baseIn,
        uint256 neutronOut,
        uint256 protonOut,
        uint256 feeToTreasury
    );
    event Fusion(
        address indexed from,
        address indexed to,
        uint256 neutronBurn,
        uint256 protonBurn,
        uint256 baseOut,
        uint256 feeToTreasury
    );
    event PriceUpdated(bytes32 indexed priceId, int64 price, uint256 timestamp);
    event TransmutePlus(   // β+
        address indexed from,
        address indexed to,
        uint256 protonIn,
        uint256 neutronOut,
        uint256 feeWad,
        int256  newDecayedVolumeBase
    );
    event TransmuteMinus(  // β-
        address indexed from,
        address indexed to,
        uint256 neutronIn,
        uint256 protonOut,
        uint256 feeWad,
        int256  newDecayedVolumeBase
    );
    event BetaParamsSet(uint256 phi0, uint256 phi1, uint256 decayPerSecondWAD);

    constructor(
        string memory _vaultName,
        address _base,
        address _pyth,
        bytes32 _basePriceId,           
        string memory _neutronName, 
        string memory _neutronSymbol,
        string memory _protonName, 
        string memory _protonSymbol,
        address _treasury, 
        uint256 _fissionFee,            
        uint256 _fusionFee,             
        uint256 _targetReserveRatioWAD
    ) {
        require(_base != address(0),  "Invalid base");
        require(_pyth != address(0),  "Invalid Pyth");
        require(_treasury != address(0), "Invalid treasury");
        require(_fissionFee < WAD, "fissionFee >= 100%");
        require(_fusionFee  < WAD, "fusionFee  >= 100%");
        require(_targetReserveRatioWAD >= WAD, "reserve ratio < 100%");

        vaultName = _vaultName;
        base = IERC20(_base);
        pyth = IPyth(_pyth);
        priceId = _basePriceId;

        neutron = new Tokeon(_neutronName, _neutronSymbol, address(this));
        proton  = new Tokeon(_protonName,  _protonSymbol,  address(this));

        treasury = _treasury;
        fissionFee = _fissionFee;
        fusionFee  = _fusionFee;

        targetReserveRatio = _targetReserveRatioWAD;

        // default β-params: no fee, no decay (can be set later by treasury)
        betaPhi0 = 0;
        betaPhi1 = 0;
        decayPerSecondWAD = WAD; // no decay
        lastDecayTs = block.timestamp;
    }

    modifier onlyTreasury() {
        require(msg.sender == treasury, "only treasury");
        _;
    }

    function setBetaParams(uint256 _phi0, uint256 _phi1, uint256 _decayPerSecondWAD) external onlyTreasury {
        require(_phi0 <= WAD && _phi1 <= WAD, "phi > 1");
        require(_decayPerSecondWAD <= WAD, "decay > 1");
        betaPhi0 = _phi0;
        betaPhi1 = _phi1;
        decayPerSecondWAD = _decayPerSecondWAD;
        emit BetaParamsSet(_phi0, _phi1, _decayPerSecondWAD);
    }

    function reserve() public view returns (uint256) {
        return base.balanceOf(address(this));
    }

    /// @dev Base/PeggedAsset price (WAD). Uses "unsafe" read; call updatePriceFeeds externally when needed.
    function getBasePriceInPeggedAsset() public view returns (uint256) {
        Price memory p = pyth.getPriceUnsafe(priceId);
        require(p.price > 0, "bad price"); 
        // convert to WAD
        if (p.expo >= 0) {
            // price * 10^{expo} * 1e18
            return uint256(uint64(p.price)) * WAD * (10 ** uint32(p.expo));
        } else {
            return (uint256(uint64(p.price)) * WAD) / (10 ** uint32(-p.expo)); 
        }
    }

    /// @dev q = 1 / r_target  (WAD)
    function qWAD() public view returns (uint256) {
        // clamp to [0,1]
        uint256 q = WAD * WAD / targetReserveRatio; 
        return q > WAD ? WAD : q;
    }

    /// @dev Price of neutron in BASE units (WAD): P° = q * R / S_n
    function neutronPriceInBase() public view returns (uint256) {
        uint256 S_n = neutron.totalSupply();
        if (S_n == 0) {
            uint256 Pbase = getBasePriceInPeggedAsset();
            return (PEG_PeggedAsset_WAD * WAD) / Pbase; // WAD * WAD / WAD = WAD
        }
        uint256 q = qWAD();
        return Math.mulDiv(q, reserve(), S_n);
    }
    /// @dev Price of proton in BASE units (WAD): P• = (1-q) * R / S_p
    function protonPriceInBase() public view returns (uint256) {
        uint256 S_p = proton.totalSupply();
        if (S_p == 0) {
            return WAD;
        }
        uint256 q = qWAD();
        uint256 oneMinusQ = WAD - q;
        return Math.mulDiv(oneMinusQ, reserve(), S_p);
    }

    function neutronPriceInPeggedAsset() external view returns (uint256) {
        return Math.mulDiv(neutronPriceInBase(), getBasePriceInPeggedAsset(), WAD);
    }
    function protonPriceInPeggedAsset() external view returns (uint256) {
        return Math.mulDiv(protonPriceInBase(),  getBasePriceInPeggedAsset(), WAD);
    }

    /// @dev Convenience: current reserve ratio vs peg (PeggedAsset): r = (R*Pbase)/(S_n*PEG)
    function reserveRatioPeggedAsset() public view returns (uint256) {
        uint256 R = reserve();
        uint256 S_n = neutron.totalSupply();
        if (R == 0) return 0;
        if (S_n == 0) return type(uint256).max;
        return Math.mulDiv(R, getBasePriceInPeggedAsset(), Math.mulDiv(S_n, PEG_PeggedAsset_WAD, WAD));
    }

    function isAboveTargetReserveRatio() external view returns (bool) {
        return reserveRatioPeggedAsset() >= targetReserveRatio;
    }

    function updatePriceFeeds(bytes[] calldata updateData) external payable {       // Price feed update passthrough 
        uint256 fee = pyth.getUpdateFee(updateData);
        require(msg.value >= fee, "fee");
        pyth.updatePriceFeeds{value: fee}(updateData);
        Price memory price = pyth.getPriceUnsafe(priceId);
        emit PriceUpdated(priceId, price.price, price.publishTime);
        if (msg.value > fee) payable(msg.sender).transfer(msg.value - fee);
    }

    /**
     * - Let net = m - fee.
     * - N_out = (net * P_base) / targetReserveRatio / PEG_PeggedAsset  ; PEG_PeggedAsset=1 so N_out = net * P_base / targetReserveRatio
     * - P_out = net - net / r   where r = targetReserveRatio / 1e18
     */
    function fission(
        uint256 m,
        address to,
        bytes[] calldata updateData
    ) external payable nonReentrant {
        require(m > 0, "amount=0");

        // 1. Update the Pyth price feed on-chain with signed data
        uint256 pythFee = 0;
        if (updateData.length > 0) {
            pythFee = pyth.getUpdateFee(updateData);
            require(msg.value >= pythFee, "insufficient oracle fee");

            // This verifies the signatures and updates the price on-chain
            pyth.updatePriceFeeds{value: pythFee}(updateData);
        }

        // 2. Read the *fresh* price (NOT unsafe) — enforce max age
        // e.g., require the price to be updated in the last 900 seconds (15 minutes)
        uint256 MAX_AGE = 900;
        Price memory p = pyth.getPriceNoOlderThan(priceId, MAX_AGE); 
        require(p.price > 0, "invalid price");

        // Convert price to WAD format  
        uint256 Pbase;
        if (p.expo >= 0) {
            Pbase = uint256(int256(p.price)) * WAD * (10 ** uint32(uint256(int256(p.expo))));
        } else {
            Pbase = (uint256(int256(p.price)) * WAD) / (10 ** uint32(uint256(int256(-p.expo))));
        }

        base.safeTransferFrom(msg.sender, address(this), m);

        uint256 fissionFeeAmount = Math.mulDiv(m, fissionFee, WAD);
        if (fissionFeeAmount > 0) {
            base.safeTransfer(treasury, fissionFeeAmount);
        }
        uint256 net = m - fissionFeeAmount;

        // N_out = net * P_base / targetReserveRatio
        uint256 nOut = Math.mulDiv(net, Pbase, targetReserveRatio);

        // P_out = net - net / r   where r = targetReserveRatio / 1e18
        uint256 pOut = net - Math.mulDiv(net, WAD, targetReserveRatio);

        neutron.mint(to, nOut);
        proton.mint(to, pOut);

        uint256 excess = msg.value > pythFee ? (msg.value - pythFee) : 0;
        if (excess > 0) {
            (bool success, ) = msg.sender.call{value: excess}("");
            require(success, "refund failed");
        }

        emit Fission(msg.sender, to, m, nOut, pOut, fissionFeeAmount);
    }


    function fusion(uint256 m, address to) external nonReentrant {
        require(m > 0, "amount=0");
        uint256 R = reserve();
        require(R > 0, "R=0");

        uint256 S_n = neutron.totalSupply();
        uint256 S_p = proton.totalSupply();
        require(S_n > 0 && S_p > 0, "empty S");

        uint256 nBurn = Math.mulDiv(m, S_n, R);
        uint256 pBurn = Math.mulDiv(m, S_p, R);

        neutron.burn(msg.sender, nBurn);
        proton .burn(msg.sender, pBurn);

        uint256 fee = Math.mulDiv(m, fusionFee, WAD);
        uint256 net = m - fee;

        base.safeTransfer(to, net);
        if (fee > 0) base.safeTransfer(treasury, fee);

        emit Fusion(msg.sender, to, nBurn, pBurn, net, fee);
    }

    function _rpow(uint256 x, uint256 n) internal pure returns (uint256 z) {
        z = (n % 2 != 0) ? x : WAD;
        for (n /= 2; n != 0; n /= 2) {
            x = Math.mulDiv(x, x, WAD);
            if (n % 2 != 0) z = Math.mulDiv(z, x, WAD);
        }
    }

    function _decayLedger() internal {
        uint256 t = block.timestamp;
        uint256 dt = t - lastDecayTs;
        if (dt == 0) return;
        if (decayPerSecondWAD == WAD) { // no decay
            lastDecayTs = t;
            return;
        }
        uint256 d = _rpow(decayPerSecondWAD, dt); // δ^{dt} (WAD)
        // decayedVolumeBase <- \bar V * δ^{dt}
        if (decayedVolumeBase != 0) {
            int256 v = decayedVolumeBase;
            if (v > 0) {
                decayedVolumeBase = int256(Math.mulDiv(uint256(v), d, WAD));
            } else {
                decayedVolumeBase = -int256(Math.mulDiv(uint256(-v), d, WAD));
            }
        }
        lastDecayTs = t;
    }

    function _betaPlusFeeWAD() internal view returns (uint256) {
        uint256 R = reserve(); 
        if (R == 0) return WAD; // saturated 
        if (betaPhi0 == 0 && betaPhi1 == 0) return 0;
        int256 v = decayedVolumeBase;
        uint256 pos = v > 0 ? uint256(v) : 0;
        uint256 term = Math.mulDiv(betaPhi1, pos, R);
        uint256 f = betaPhi0 + term;
        return f > WAD ? WAD : f;
    }

    function _betaMinusFeeWAD() internal view returns (uint256) {
        uint256 R = reserve();
        if (R == 0) return WAD;
        if (betaPhi0 == 0 && betaPhi1 == 0) return 0;
        int256 v = decayedVolumeBase;
        uint256 neg = v < 0 ? uint256(-v) : 0;
        uint256 term = Math.mulDiv(betaPhi1, neg, R);
        uint256 f = betaPhi0 + term;
        return f > WAD ? WAD : f;
    }

    /**
     * β+ : convert proton -> neutron
     * - Value path (in BASE): gross = protonIn * P•_base
     * - Apply fee φβ+ on output value
     * - neutronOut = (gross * (1-φ)) / P°_base
     * - Update \bar V += +gross (decayed ledger)
     */
    function transmuteProtonToNeutron(uint256 protonIn, address to) external nonReentrant returns (uint256 neutronOut, uint256 feeWad) {
        require(protonIn > 0, "amount=0");
        uint256 Pp_base = protonPriceInBase(); 
        uint256 Pn_base = neutronPriceInBase(); 
        require(Pp_base > 0 && Pn_base > 0, "bad price");

        // Pull/burn input
        proton.burn(msg.sender, protonIn);

        // gross value in BASE (WAD scaling): protonIn * Pp_base / WAD
        uint256 grossBase = Math.mulDiv(protonIn, Pp_base, WAD);

        _decayLedger();
        feeWad = _betaPlusFeeWAD();
        uint256 netBase = Math.mulDiv(grossBase, (WAD - feeWad), WAD);

        neutronOut = Math.mulDiv(netBase, WAD, Pn_base);
        neutron.mint(to, neutronOut);

        // \bar V update: +grossBase
        decayedVolumeBase += int256(grossBase);
        emit TransmutePlus(msg.sender, to, protonIn, neutronOut, feeWad, decayedVolumeBase);
    }

    /**
     * β- : convert neutron -> proton
     * - Value path (in BASE): gross = neutronIn * P°_base
     * - Apply fee φβ- on output value
     * - protonOut = (gross * (1-φ)) / P•_base
     * - Update \bar V += -gross (decayed ledger)
     */
    function transmuteNeutronToProton(uint256 neutronIn, address to) external nonReentrant returns (uint256 protonOut, uint256 feeWad) {
        require(neutronIn > 0, "amount=0");

        uint256 Pp_base = protonPriceInBase();  
        uint256 Pn_base = neutronPriceInBase(); 
        require(Pp_base > 0 && Pn_base > 0, "bad price");
        neutron.burn(msg.sender, neutronIn);
        uint256 grossBase = Math.mulDiv(neutronIn, Pn_base, WAD);

        _decayLedger();
        feeWad = _betaMinusFeeWAD();
        uint256 netBase = Math.mulDiv(grossBase, (WAD - feeWad), WAD);

        protonOut = Math.mulDiv(netBase, WAD, Pp_base);
        proton.mint(to, protonOut);
        decayedVolumeBase -= int256(grossBase);
        emit TransmuteMinus(msg.sender, to, neutronIn, protonOut, feeWad, decayedVolumeBase);
    }

    function neutronSupply() external view returns (uint256) { return neutron.totalSupply(); }
    function protonSupply()  external view returns (uint256) { return proton.totalSupply();  }
    function baseDecimals()  external view returns (uint8) { return IERC20Metadata(address(base)).decimals(); }
}