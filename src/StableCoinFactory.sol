// SPDX-License-Identifier: AEL
pragma solidity ^0.8.0;

import "./StableCoin.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract StableCoinFactory is Ownable {
    // Events
    event ReactorDeployed(
        address indexed reactor,
        address indexed base,
        address indexed treasury,
        string vaultName,
        string neutronName,
        string neutronSymbol,
        string protonName,
        string protonSymbol,
        uint256 fissionFee,
        uint256 fusionFee
    );
    
    event ReactorDeployedWithOracle(
        address indexed reactor,
        address indexed base,
        address indexed pyth,
        bytes32 priceId,
        uint256 maxPriceAge
    );
    
    // Array to track all deployed reactors
    address[] public deployedReactors;
    
    // Mapping from base token to deployed reactors
    mapping(address => address[]) public reactorsByBase;
    
    constructor() Ownable(msg.sender) {}
    
    /**
     * @dev Deploy a new StableCoinReactor with Pyth oracle integration
     * @param _vaultName Name identifier for this vault deployment
     * @param _base Address of the ERC20 token used as reserve asset
     * @param _pyth Address of the Pyth oracle contract
     * @param _priceId Pyth price feed ID for the stable token target price
     * @param _maxPriceAge Maximum age for price data in seconds
     * @param _neutronName Name for the stable token (neutron)
     * @param _neutronSymbol Symbol for the stable token (neutron)
     * @param _protonName Name for the volatile token (proton)
     * @param _protonSymbol Symbol for the volatile token (proton)
     * @param _treasury Address that receives fees
     * @param _fissionFee Fee for fission operations (1e18 scale, e.g., 0.005e18 = 0.5%)
     * @param _fusionFee Fee for fusion operations (1e18 scale, e.g., 0.005e18 = 0.5%)
     */
    function deployReactor(
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
    ) public returns (address) {
        require(bytes(_vaultName).length > 0, "Empty vault name");
        require(_base != address(0), "Invalid base token");
        require(_pyth != address(0), "Invalid Pyth address");
        require(_treasury != address(0), "Invalid treasury");
        require(_fissionFee < 1e18, "fissionFee >= 100%");
        require(_fusionFee < 1e18, "fusionFee >= 100%");
        require(_maxPriceAge > 0, "Invalid max price age");
        require(_priceId != bytes32(0), "Invalid price ID");
        require(bytes(_neutronName).length > 0, "Empty neutron name");
        require(bytes(_neutronSymbol).length > 0, "Empty neutron symbol");
        require(bytes(_protonName).length > 0, "Empty proton name");
        require(bytes(_protonSymbol).length > 0, "Empty proton symbol");
        
        // Deploy new StableCoinReactor
        StableCoinReactor reactor = new StableCoinReactor(
            _vaultName,
            _base,
            _pyth,
            _priceId,
            _maxPriceAge,
            _neutronName,
            _neutronSymbol,
            _protonName,
            _protonSymbol,
            _treasury,
            _fissionFee,
            _fusionFee
        );
        
        address reactorAddress = address(reactor);
        
        // Track the deployment
        deployedReactors.push(reactorAddress);
        reactorsByBase[_base].push(reactorAddress);
        
        emit ReactorDeployed(
            reactorAddress,
            _base,
            _treasury,
            _vaultName,
            _neutronName,
            _neutronSymbol,
            _protonName,
            _protonSymbol,
            _fissionFee,
            _fusionFee
        );
        
        emit ReactorDeployedWithOracle(
            reactorAddress,
            _base,
            _pyth,
            _priceId,
            _maxPriceAge
        );
        
        return reactorAddress;
    }
    
    /**
     * @dev Get the total number of deployed reactors
     */
    function getDeployedReactorsCount() external view returns (uint256) {
        return deployedReactors.length;
    }
    
    /**
     * @dev Get all deployed reactors
     */
    function getAllDeployedReactors() external view returns (address[] memory) {
        return deployedReactors;
    }
    /**
     * @dev Get reactor info for monitoring
     */
    function getReactorInfo(address reactorAddress) external view returns (
        string memory vaultName,
        address base,
        address neutron,
        address proton,
        address treasury,
        uint256 reserve,
        uint256 neutronSupply,
        uint256 protonSupply,
        uint256 reserveRatio,
        bool isHealthy
    ) {
        StableCoinReactor reactor = StableCoinReactor(reactorAddress);
        
        vaultName = reactor.vaultName();
        base = address(reactor.base());
        neutron = address(reactor.neutron());
        proton = address(reactor.proton());
        treasury = reactor.treasury();
        reserve = reactor.reserve();
        neutronSupply = reactor.neutronSupply();
        protonSupply = reactor.protonSupply();
        
        (reserveRatio, , isHealthy, ,) = reactor.systemHealth();
    }
}