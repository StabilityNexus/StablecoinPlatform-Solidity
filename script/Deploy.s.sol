// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "../lib/forge-std/src/Script.sol";
import {console} from "../lib/forge-std/src/console.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";

contract DeployStableCoinFactory is Script {
    
    StableCoinFactory public factory;
    function setUp() public {}

    function run() public {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        factory = new StableCoinFactory();

        console.log("Factory Deployed: ", address(factory));

        vm.stopBroadcast();
    }
}
