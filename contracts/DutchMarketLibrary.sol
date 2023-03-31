// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

enum Mode {
    DepositWithdraw, // 0
    Offer, // 1
    BidOpening, // 2
    Matching // 3
}

struct Offer {
    bytes32 id;
    uint256 amount;
    uint256 pricePerToken; // in 18 decimals
    address seller;
    address token;
    bool exists;
}

struct OpenBid {
    bytes32 id;
    uint256 amount;
    uint256 pricePerToken; // in 18 decimals
    address buyer;
    address token;
    bool exists;
}

library DutchMarketLibrary {
    // Works only for ethereum where block time is 12 seconds, wont work for roll ups where block time is 2 seconds
    // block time approx = 12s i.e 1 block every 12 seconds -> how many block in 5 mins  ?
    // 5 mins = 5*60s  in terms of blocks this is 25 blocks
    // enum is uint8

    function removeFromBytesArray(
        uint256 index,
        bytes32[] storage array
    ) internal {
        if (index >= array.length) return;

        for (uint256 i = index; i < array.length - 1; i++) {
            array[i] = array[i + 1];
        }
        array.pop();
    }

    function removeFromOpenBidArray(
        uint256 index,
        OpenBid[] storage array
    ) internal {
        if (index >= array.length) return;

        for (uint256 i = index; i < array.length - 1; i++) {
            array[i] = array[i + 1];
        }
        array.pop();
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
