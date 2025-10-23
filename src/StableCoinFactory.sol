// SPDX-License-Identifier: AEL
pragma solidity ^0.8.20;

import "./StableCoin.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract StableCoinFactory is Ownable {
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
        uint256 fusionFee,
        uint256 targetReserveRatioWAD
    );

    event ReactorDeployedWithOracle(
        address indexed reactor,
        address indexed base,
        bytes32 basePriceId
    );

    address[] public deployedReactors;
    mapping(address => address[]) public reactorsByBase;

    constructor() Ownable(msg.sender) {}

    /**
     * Deploy a new Reactor
     * @param _vaultName   name label
     * @param _base        ERC20 reserve
     * @param _basePriceId Pyth feed for BASE/USD
     * @param _neutronName name of neutron token
     * @param _neutronSymbol symbol of neutron token
     * @param _protonName  name of proton token
     * @param _protonSymbol symbol of proton token
     * @param _treasury    fees / governance
     * @param _fissionFee  WAD
     * @param _fusionFee   WAD
     * @param _targetReserveRatioWAD e.g., 4e18 for 400%
     */
    function deployReactor(
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
    ) public returns (address) {
        require(bytes(_vaultName).length > 0, "Empty vault name");
        require(_base != address(0), "Invalid base");
        require(_pyth != address(0), "Invalid Pyth");
        require(_treasury != address(0), "Invalid treasury");
        require(_fissionFee < 1e18, "fissionFee >= 100%");
        require(_fusionFee  < 1e18, "fusionFee  >= 100%");
        require(_targetReserveRatioWAD >= 1e18, "reserve ratio < 100%");

        StableCoinReactor reactor = new StableCoinReactor(
            _vaultName,
            _base,
            _pyth,
            _basePriceId,
            _neutronName,
            _neutronSymbol,
            _protonName,
            _protonSymbol,
            _treasury,
            _fissionFee,
            _fusionFee,
            _targetReserveRatioWAD
        );

        address reactorAddress = address(reactor);
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
            _fusionFee,
            _targetReserveRatioWAD
        );

        emit ReactorDeployedWithOracle(
            reactorAddress,
            _base,
            _basePriceId
        );

        return reactorAddress;
    }

    function getDeployedReactorsCount() external view returns (uint256) {
        return deployedReactors.length;
    }

    function getAllDeployedReactors() external view returns (address[] memory) {
        return deployedReactors;
    }
}
