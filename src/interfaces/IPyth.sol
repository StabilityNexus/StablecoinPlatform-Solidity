// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

struct Price {
    int64 price;
    uint64 conf;
    int32 expo;
    uint256 publishTime;
}

struct PriceData {
    int64 price;
    uint64 conf;
    int32 expo;
    uint256 publishTime;
}

interface IPyth {
    
    function getValidTimePeriod() external view returns (uint validTimePeriod);
    
    function getPrice(bytes32 id) external view returns (Price memory price);
    function getEmaPrice(bytes32 id) external view returns (Price memory price);
    function getPriceUnsafe(bytes32 id) external view returns (Price memory price);
    
    function getPriceNoOlderThan(bytes32 id, uint age) external view returns (Price memory price);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
    
    function updatePriceFeedsIfNecessary(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64[] calldata publishTimes
    ) external payable;
    
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint feeAmount);
}