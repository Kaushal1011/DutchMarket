// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

import "./BokkyPooBahsRedBlackTreeLibrary.sol";
import {DutchMarketLibrary, Mode, Offer, OpenBid} from "./DutchMarketLibrary.sol";

// TODO: add events wherever required
// TODO: add comments wherever required
// TODO: add tests
// TODO: check settle function

/**
 * @title DutchMarket
 */
contract DutchMarket is EIP712 {
    address owner;

    // store native balance of a user (address -> balance)
    mapping(address => uint) public nativeBalance;
    // store token balances of a user mappping of (user address -> token address -> balance)
    mapping(address => mapping(address => uint)) public tokenBalances;
    // store if account exists // change the bool to struct when extra details of user is required
    mapping(address => bool) public accounts;

    // TODO: Think gas optimization for gas as the offers mapping can be made nested
    // to incorporate priceToOfferId but does this actually use less gas as same storage ops are done
    // This is easier to change and maintain

    // storage for offers (mapping of offer by a user for (hash(tokenddress,useraddress)) -> offer struct)
    mapping(bytes32 => Offer) public offers;
    // redblack tree for storing offers in sorted order (mapping of token address -> tree)
    mapping(address => BokkyPooBahsRedBlackTreeLibrary.Tree) offerTree;
    // mapping to store pricePerToken to offerIds
    mapping(uint256 => bytes32[]) priceToOfferId;

    // storage for blind bidding system

    // store bid details
    mapping(address => bytes32[]) public bids;

    // store open bids
    OpenBid[] public openBids;

    using Counters for Counters.Counter;

    mapping(address => Counters.Counter) private _nonces;

    // solhint-disable-next-line var-name-mixedcase
    bytes32 private constant _BID_TYPEHASH =
        keccak256(
            "PlaceAnonymousBlindBid(bytes32 blindBid,uint256 nonce,uint256 deadline)"
        );

    // extra

    uint256[] offersToDelete;

    // modifiers
    modifier onlyDepositWithdraw() {
        // Document E1 is Deposit,Withdraw,CreateAccount called outside of mode
        // Shorter Strings in require save on contracts size( and gas ?)
        require(getModeByTimeStamp() == Mode.DepositWithdraw, "E1");
        _;
    }

    modifier onlyOffer() {
        require(getModeByTimeStamp() == Mode.Offer, "E2");
        _;
    }

    modifier onlyBidOpening() {
        require(getModeByTimeStamp() == Mode.BidOpening, "E3");
        _;
    }

    modifier onlyMatching() {
        require(getModeByTimeStamp() == Mode.Matching, "E4");
        _;
    }

    modifier nonZeroValue() {
        // E4 is zero eth sent for payable function requiring pay
        require(msg.value != 0, "E4");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "E5");
        _;
    }

    constructor() EIP712("DutchMarket", "1") {
        owner = msg.sender;
    }

    // function getModeByBlockNumber() public view returns (Mode) {
    //     uint256 num = block.number % 100;

    //     if (num >= 0 && num < 25) {
    //         return Mode.DepositWithdraw;
    //     } else if (num >= 25 && num < 50) {
    //         return Mode.Offer;
    //     } else if (num >= 50 && num < 75) {
    //         return Mode.BidOpening;
    //     } else {
    //         return Mode.Matching;
    //     }
    // }

    // Timestamp implementation to get mode
    function getModeByTimeStamp() public view returns (Mode) {
        uint256 secs = block.timestamp % (60 * 60);
        uint minute = secs / (60 * 60);
        if (minute <= 4) {
            return Mode.DepositWithdraw;
        } else if (((minute >= 5) && (minute <= 9))) {
            return Mode.Offer;
        } else if (((minute >= 10) && (minute <= 14))) {
            return Mode.BidOpening;
        } else if (((minute >= 20) && (minute <= 24))) {
            return Mode.DepositWithdraw;
        } else if (((minute >= 25) && (minute <= 29))) {
            return Mode.BidOpening;
        } else if (((minute >= 30) && (minute <= 34))) {
            return Mode.BidOpening;
        } else if (((minute >= 40) && (minute <= 44))) {
            return Mode.DepositWithdraw;
        } else if (((minute >= 45) && (minute <= 49))) {
            return Mode.BidOpening;
        } else if (((minute >= 50) && (minute <= 54))) {
            return Mode.BidOpening;
        } else {
            return Mode.Matching;
        }
    }

    /**
     * @dev See {IERC20Permit-nonces}.
     */
    function nonces(address _owner) public view virtual returns (uint256) {
        return _nonces[_owner].current();
    }

    /**
     * @dev See {IERC20Permit-DOMAIN_SEPARATOR}.
     */
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @dev "Consume a nonce": return the current value and increment.
     *
     * _Available since v4.1._
     */
    function _useNonce(
        address _owner
    ) internal virtual returns (uint256 current) {
        Counters.Counter storage nonce = _nonces[_owner];
        current = nonce.current();
        nonce.increment();
    }

    function createAccount() public payable onlyDepositWithdraw nonZeroValue {
        // create an account, set true in accounts
        accounts[msg.sender] = true;
        nativeBalance[msg.sender] = msg.value;
    }

    // deposit(){value:10*10**18} user sends ether while callng this function as this payable
    function deposit() public payable onlyDepositWithdraw nonZeroValue {
        // account not created
        require(accounts[msg.sender] == true, "E5");
        nativeBalance[msg.sender] += msg.value;
    }

    // allowance to this contract should be given before callng this function
    function depositERC20(
        address token,
        uint256 amount
    ) public onlyDepositWithdraw {
        require(amount != 0, "Zero Amount");

        // read about how erc20 tokens work if you havent already
        bool success = IERC20(token).transferFrom(
            msg.sender,
            address(this),
            amount
        );

        require(success, "Failed Transfer ERC20");

        // only add balance once the transfer has taken place (saves from using rentrancy guard here)
        tokenBalances[msg.sender][token] += amount;
    }

    // receipient is the eoa that will receive funds
    function withdraw(
        uint256 amount,
        address payable receipient
    ) public onlyDepositWithdraw {
        require(amount <= nativeBalance[msg.sender]);
        nativeBalance[msg.sender] -= amount;
        (bool sent, ) = receipient.call{value: amount}("");
        require(sent, "Failed to send Ether");
    }

    function withdrawERC20(
        address token,
        uint256 amount
    ) public onlyDepositWithdraw {
        require(tokenBalances[msg.sender][token] >= amount, "Amount Too High");

        tokenBalances[msg.sender][token] -= amount;

        // send funds back to the user from dutch market contract
        bool success = IERC20(token).transfer(msg.sender, amount);

        require(success, "Failed Transfer ERC20");
    }

    function makeNewOffer(
        address tokenAddress,
        uint256 amount,
        uint256 pricePerToken
    ) public onlyOffer {
        require(
            tokenBalances[msg.sender][tokenAddress] >= amount,
            "Amount Too High"
        );

        require(pricePerToken != 0, "Zero Price");

        require(
            offers[keccak256(abi.encodePacked(tokenAddress, msg.sender))]
                .exists == false,
            "Offer Exists"
        );

        // create a new offer
        Offer memory newOffer = Offer({
            id: keccak256(abi.encodePacked(tokenAddress, msg.sender)),
            seller: msg.sender,
            token: tokenAddress,
            amount: amount,
            pricePerToken: pricePerToken,
            exists: true
        });

        // add offer to offers mapping
        offers[newOffer.id] = newOffer;

        // add offer to offerTree if doesnt already exists
        if (
            !BokkyPooBahsRedBlackTreeLibrary.exists(
                offerTree[tokenAddress],
                pricePerToken
            )
        ) {
            BokkyPooBahsRedBlackTreeLibrary.insert(
                offerTree[tokenAddress],
                pricePerToken
            );
        }

        // add offer to priceToOfferId
        priceToOfferId[pricePerToken].push(newOffer.id);
    }

    function withdrawOffer(address tokenAddress) public onlyOffer {
        require(
            offers[keccak256(abi.encodePacked(tokenAddress, msg.sender))]
                .exists == true,
            "Offer Doesnt Exist"
        );

        Offer memory useroffer = offers[
            keccak256(abi.encodePacked(tokenAddress, msg.sender))
        ];

        // remove offer from offers mapping
        delete offers[useroffer.id];

        // remove offer from offerTree
        BokkyPooBahsRedBlackTreeLibrary.remove(
            offerTree[tokenAddress],
            useroffer.pricePerToken
        );

        // remove offer from priceToOfferId and rebalance array
        for (
            uint256 i = 0;
            i < priceToOfferId[useroffer.pricePerToken].length;
            i++
        ) {
            if (
                priceToOfferId[useroffer.pricePerToken][i] ==
                keccak256(abi.encodePacked(tokenAddress, msg.sender))
            ) {
                DutchMarketLibrary.removeFromBytesArray(
                    i,
                    priceToOfferId[useroffer.pricePerToken]
                );
            }
        }
    }

    function reducePriceOnOffer(
        address tokenAddress,
        uint256 newPrice
    ) public onlyOffer {
        require(
            offers[keccak256(abi.encodePacked(tokenAddress, msg.sender))]
                .exists == true,
            "Offer Doesnt Exist"
        );

        Offer memory useroffer = offers[
            keccak256(abi.encodePacked(tokenAddress, msg.sender))
        ];

        require(newPrice < useroffer.pricePerToken, "New Price Too High");

        // remove offer from offerTree
        BokkyPooBahsRedBlackTreeLibrary.remove(
            offerTree[tokenAddress],
            useroffer.pricePerToken
        );

        // remove offer from priceToOfferId and rebalance array
        for (
            uint256 i = 0;
            i < priceToOfferId[useroffer.pricePerToken].length;
            i++
        ) {
            if (
                priceToOfferId[useroffer.pricePerToken][i] ==
                keccak256(abi.encodePacked(tokenAddress, msg.sender))
            ) {
                DutchMarketLibrary.removeFromBytesArray(
                    i,
                    priceToOfferId[useroffer.pricePerToken]
                );
            }
        }

        // update offer price
        offers[useroffer.id].pricePerToken = newPrice;

        // add offer to offerTree if doesnt already exists
        if (
            !BokkyPooBahsRedBlackTreeLibrary.exists(
                offerTree[tokenAddress],
                newPrice
            )
        ) {
            BokkyPooBahsRedBlackTreeLibrary.insert(
                offerTree[tokenAddress],
                newPrice
            );
        }

        // add offer to priceToOfferId
        priceToOfferId[newPrice].push(useroffer.id);
    }

    function blindABid(
        address tokenAddress,
        uint256 amount,
        uint256 pricePerToken,
        address bidder,
        bytes32 secret
    ) public pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    tokenAddress,
                    amount,
                    pricePerToken,
                    bidder,
                    secret
                )
            );
    }

    function placeAnonymousBlindBid(
        bytes32 blindBid,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public onlyBidOpening {
        require(deadline >= block.timestamp, "Deadline Passed");

        bytes32 structHash = keccak256(
            abi.encode(_BID_TYPEHASH, blindBid, _useNonce(owner), deadline)
        );

        bytes32 hash = _hashTypedDataV4(structHash);

        address signer = ECDSA.recover(hash, v, r, s);

        bids[signer].push(blindBid);
    }

    function placeBlindBid(bytes32 blindBid) public onlyBidOpening {
        bids[msg.sender].push(blindBid);
    }

    function openBlindBids(
        OpenBid[] memory openBids_,
        bool[] memory fakes,
        bytes32[] memory secretBids
    ) public onlyBidOpening {
        uint length = bids[msg.sender].length;
        require(openBids_.length == length);
        require(fakes.length == length);
        require(secretBids.length == length);

        for (uint i = 0; i < length; i++) {
            (address tokenAddress, uint256 amount, uint256 pricePerToken) = (
                openBids_[i].token,
                openBids_[i].amount,
                openBids_[i].pricePerToken
            );

            require(
                bids[msg.sender][i] ==
                    keccak256(
                        abi.encodePacked(
                            tokenAddress,
                            amount,
                            pricePerToken,
                            secretBids[i]
                        )
                    ),
                "Bid Doesnt Match"
            );

            if (!fakes[i]) {
                openBids.push(openBids_[i]);
            }
        }
    }

    function withdrawBlindBids() public onlyBidOpening {
        delete bids[msg.sender];
    }

    function withdrawOpenBid(OpenBid memory userBid) public onlyBidOpening {
        for (uint i = 0; i < openBids.length; i++) {
            if (
                openBids[i].token == userBid.token &&
                openBids[i].amount == userBid.amount &&
                openBids[i].pricePerToken == userBid.pricePerToken
            ) {
                DutchMarketLibrary.removeFromOpenBidArray(i, openBids);
            }
        }
    }

    function settleBid(uint256 bidId) internal {
        OpenBid memory bid = openBids[bidId];

        uint256 pricePerToken = bid.pricePerToken;
        address tokenAddress = bid.token;
        uint256 amount = bid.amount;

        while (amount != 0) {
            // get the lowest possible offer
            uint256 lowestOffer = BokkyPooBahsRedBlackTreeLibrary.first(
                offerTree[tokenAddress]
            );

            if (lowestOffer > pricePerToken) {
                // no offers left
                break;
            }

            uint256 buyerCapacity = nativeBalance[bid.buyer] / pricePerToken;

            for (uint256 j = 0; j < priceToOfferId[lowestOffer].length; j++) {
                Offer memory offer = offers[priceToOfferId[lowestOffer][j]];

                // check if buyer has enough native balance
                // check if seller has enough tokens

                // safegaurds if seller has less tokens than offer amount
                uint256 maxSaleAmountPossible = DutchMarketLibrary.min(
                    tokenBalances[offer.seller][tokenAddress],
                    offer.amount
                );

                buyerCapacity = nativeBalance[bid.buyer] / pricePerToken;

                // safeguards if buyer has less native balance than amount in bid
                uint256 maxBuyPossible = DutchMarketLibrary.min(
                    buyerCapacity,
                    amount
                );

                uint256 amountToBuy = DutchMarketLibrary.min(
                    maxSaleAmountPossible,
                    maxBuyPossible
                );

                // transfer balance in internal storage
                tokenBalances[offer.seller][tokenAddress] -= amountToBuy;
                tokenBalances[bid.buyer][tokenAddress] += amountToBuy;

                nativeBalance[offer.seller] += amountToBuy * pricePerToken;
                nativeBalance[bid.buyer] -= amountToBuy * pricePerToken;

                // update offer amount
                offers[offer.id].amount -= amountToBuy;

                if (offers[offer.id].amount == 0) {
                    // clean up: remove offer from array
                    offersToDelete.push(j);
                }

                // update amount
                amount = (amount - amountToBuy);

                // update storage
                openBids[bidId].amount = amount;

                buyerCapacity = nativeBalance[bid.buyer] / pricePerToken;

                if (amount == 0 || buyerCapacity == 0) {
                    // remove bid

                    DutchMarketLibrary.removeFromOpenBidArray(bidId, openBids);

                    break;
                }
            }

            // clean up: remove offers from priceToOfferId array
            for (uint256 j = 0; j < offersToDelete.length; j++) {
                DutchMarketLibrary.removeFromBytesArray(
                    offersToDelete[j],
                    priceToOfferId[lowestOffer]
                );
            }

            if (priceToOfferId[lowestOffer].length == 0) {
                // clean up: remove offer from offerTree
                BokkyPooBahsRedBlackTreeLibrary.remove(
                    offerTree[tokenAddress],
                    lowestOffer
                );
            }

            // make storage array to back to 0 length
            delete offersToDelete;

            if (buyerCapacity == 0) {
                break;
            }
        }
    }

    // 0 settles all bids, avoid this as it may read gasLimit, use a smaller number
    // This function is called by the owner during the settlement period to settle bids
    function matchBidsAndSettle(uint256 bidsToSettle) public onlyOwner {
        uint256 length = bidsToSettle != 0 ? bidsToSettle : openBids.length;

        for (uint256 i = 0; i < length; i++) {
            settleBid(i);
        }
    }
}
