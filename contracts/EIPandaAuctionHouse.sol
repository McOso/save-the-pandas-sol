// SPDX-License-Identifier: GPL-3.0

/// @title The Save the EIPandas Auction House

/*************************************************************************************************
    )\ )                       )    )              )\ ) )\ )    (      ( /(  )\ )    (      )\ )  
    (()/(    )   )      (    ( /( ( /(    (    (   (()/((()/(    )\     )\())(()/(    )\    (()/(  
    /(_))( /(  /((    ))\   )\()))\())  ))\   )\   /(_))/(_))((((_)(  ((_)\  /(_))((((_)(   /(_)) 
    (_))  )(_))(_))\  /((_) (_))/((_)\  /((_) ((_) (_)) (_))   )\ _ )\  _((_)(_))_  )\ _ )\ (_))   
    / __|((_)_ _)((_)(_))   | |_ | |(_)(_))   | __||_ _|| _ \  (_)_\(_)| \| | |   \ (_)_\(_)/ __|  
    \__ \/ _` |\ V / / -_)  |  _|| ' \ / -_)  | _|  | | |  _/   / _ \  | .` | | |) | / _ \  \__ \  
    |___/\__,_| \_/  \___|   \__||_||_|\___|  |___||___||_|    /_/ \_\ |_|\_| |___/ /_/ \_\ |___/  
                                                                                               
 *************************************************************************************************/

// LICENSE
// EIPandaAuctionHouse.sol is a modified version of Nounders DAO's NounsAuctionHouse.sol:
// https://github.com/nounsDAO/nouns-monorepo/blob/10bb478328bdb5f4c5efffed9a8c5186f9fe974a/packages/nouns-contracts/contracts/NounsAuctionHouse.sol
//
// NounsAuctionHouse.sol source code Copyright Nounders DAO licensed under the GPL-3.0 license.
// With modifications by EIPanda community.

pragma solidity ^0.8.15;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

// found here: https://github.com/lidofinance/lido-dao/blob/cadffa46a2b8ed6cfa1127fca2468bae1a82d6bf/contracts/0.8.9/WithdrawalQueue.sol#LL125C57-L125C77
interface ILidoWithdrawalQueue {
    function requestWithdrawals(uint256[] calldata _amounts, address _owner) external returns (uint256[] memory requestIds);
}

contract EIPandaAuctionHouse is ReentrancyGuard, Ownable {

    struct Auction {
        uint256 pandaId;
        uint256 startTime;
        uint256 endTime;
        uint256 highestBid;
        address highestBidder;
    }

    // The EIPandas NFT contract
    IERC721 public eipandas = IERC721(0xA09129080eD12CF1B1C7a6e723C63E0820E9D3ae);

    // The Lido stETH token contract
    IERC20 public lidoStETH = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);

    // Lido withdraw contract
    ILidoWithdrawalQueue public lidoWithdrawalQueue = ILidoWithdrawalQueue(0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1);

    // The minimum amount of time left in an auction after a new bid is created
    uint256 public timeBuffer = 1200; // 20 minutes

    // The minimum price accepted in an auction
    uint256 public reservePrice = 0.01 ether;

    // The minimum percentage difference between the last bid amount and the current bid
    uint8 public minBidIncrementPercentage = 10; // 10%

    // The duration of a single auction
    uint256 public duration = 1 days;

    // The current auction
    Auction public auction;

    // active auction flag
    bool public auctionInProgress;

    // array of pandas to be auctioned
    uint256[] public pandasToAuction;

    event PandaDeposited(uint256 tokenId);
    event AuctionStarted(uint256 tokenId, uint256 endTime);
    event AuctionSuccessful(uint256 tokenId, address indexed buyer, uint256 totalPrice);
    event PandaKilled(uint256 tokenId);
    event AuctionCreated(uint256 indexed nounId, uint256 startTime, uint256 endTime);
    event AuctionBid(uint256 indexed nounId, address sender, uint256 value, bool extended);
    event AuctionExtended(uint256 indexed nounId, uint256 endTime);
    event AuctionSettled(uint256 indexed nounId, address winner, uint256 amount);
    event AuctionTimeBufferUpdated(uint256 timeBuffer);
    event AuctionReservePriceUpdated(uint256 reservePrice);
    event AuctionMinBidIncrementPercentageUpdated(uint256 minBidIncrementPercentage);

    constructor(address _eipandasAddress, address _lidoStETHAddress) {
        eipandas = IERC721(_eipandasAddress);
        lidoStETH = IERC20(_lidoStETHAddress);
    }

    modifier activeAuction() {
        require(auctionInProgress, "There is no active auction");
        _;
    }

    modifier noActiveAuction() {
        require(!auctionInProgress, "An auction is already in progress");
        _;
    }

    /**
     * @notice Settle the current auction, fetch a new panda, and put it up for auction.
     */
    function settleCurrentAndCreateNewAuction() external nonReentrant activeAuction {
        _settleAuction();
        _startAuction();
    }

    /**
     * @notice Place a bid to save a Panda, with a given amount.
     * @dev This contract only accepts payment in stETH.
     */

    function placeBid(uint256 _bidAmount) external nonReentrant activeAuction{
        Auction memory _auction = auction;

        require(block.timestamp < _auction.endTime, 'Auction expired');
        require(_bidAmount >= reservePrice, 'Must send at least reservePrice');
        require(
            _bidAmount >= _auction.highestBid + ((_auction.highestBid * minBidIncrementPercentage) / 100),
            'Must send more than last bid by minBidIncrementPercentage amount'
        );

        // Transfer the stETH tokens from the bidder to the contract
        require(lidoStETH.transferFrom(msg.sender, address(this), _bidAmount), "Insufficent stETH or approval not set");

        address lastBidder_ = _auction.highestBidder;

        // Refund the last bidder, if applicable
        if (lastBidder_ != address(0)) {
            // Transfer the previous highest bid back to the bidder
            lidoStETH.transfer(lastBidder_, _auction.highestBid);
        }

        auction.highestBid = _bidAmount;
        auction.highestBidder = msg.sender;

        // Extend the auction if the bid was received within `timeBuffer` of the auction end time
        bool extended = _auction.endTime - block.timestamp < timeBuffer;
        if (extended) {
            auction.endTime = _auction.endTime = block.timestamp + timeBuffer;
        }

        emit AuctionBid(_auction.pandaId, auction.highestBidder, auction.highestBid, extended);

        if (extended) {
            emit AuctionExtended(_auction.pandaId, _auction.endTime);
        }
    }

    /**
     * @notice Set the auction time buffer.
     * @dev Only callable by the owner.
     */
    function setTimeBuffer(uint256 _timeBuffer) external onlyOwner {
        timeBuffer = _timeBuffer;

        emit AuctionTimeBufferUpdated(_timeBuffer);
    }

    /**
     * @notice Set the auction reserve price.
     * @dev Only callable by the owner.
     */
    function setReservePrice(uint256 _reservePrice) external onlyOwner {
        reservePrice = _reservePrice;

        emit AuctionReservePriceUpdated(_reservePrice);
    }

    /**
     * @notice Set the auction minimum bid increment percentage.
     * @dev Only callable by the owner.
     */
    function setMinBidIncrementPercentage(uint8 _minBidIncrementPercentage) external onlyOwner {
        minBidIncrementPercentage = _minBidIncrementPercentage;

        emit AuctionMinBidIncrementPercentageUpdated(_minBidIncrementPercentage);
    }

    /**
     * @notice Set the auction duration time.
     * @dev Only callable by the owner.
     */
    function setDuration(uint256 _duration) external onlyOwner {
        duration = _duration;
    }

    function pandasToSave() external view returns (uint256) {
        return pandasToAuction.length;
    }

    function depositPandas(uint256[] calldata _tokenIds) external nonReentrant {
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            _depositPanda(_tokenIds[i]);
        }
    }

    function _depositPanda(uint256 _tokenId) internal {
        require(eipandas.ownerOf(_tokenId) == msg.sender, "Ser, this is not your panda");
        eipandas.safeTransferFrom(msg.sender, address(this), _tokenId);
        pandasToAuction.push(_tokenId);
        emit PandaDeposited(_tokenId);
    }

    /**
     * @notice Create an auction.
     * @dev Store the auction details in the `auction` state variable and emit an AuctionCreated event.
     * Check to make sure there are pandas to auction. Start new auction with panda using LIFO
     */
    function _startAuction() internal nonReentrant noActiveAuction {
        // check if there are any pandas to auction
        uint256 numPandasToAuction_ = pandasToAuction.length;
        require(numPandasToAuction_ > 0, "No pandas to save at this time");

        // grab a panda from the array using LIFO
        uint256 pandaId_ = pandasToAuction[numPandasToAuction_ - 1];
        pandasToAuction.pop();

        uint256 startTime_ = block.timestamp;
        uint256 endTime_ = startTime_ + duration;

        auction = Auction({
            pandaId: pandaId_,
            startTime: startTime_,
            endTime: endTime_,
            highestBid: 0,
            highestBidder: address(0)
        });

        auctionInProgress = true;

        emit AuctionCreated(pandaId_, startTime_, endTime_);
    }

    /**
     * @notice Settle an auction, finalizing the bid and paying out to the owner.
     * @dev If there are no bids, the Panda is burned.
     */
    function _settleAuction() internal nonReentrant activeAuction {
        Auction memory _auction = auction;

        require(block.timestamp >= _auction.endTime, "Auction hasn't completed");


        if (_auction.highestBidder == address(0)) {
            // R.I.P.
            eipandas.safeTransferFrom(address(this), address(0x000000000000000000000000000000000000dEaD), _auction.pandaId);
            emit PandaKilled(_auction.pandaId);
        } else {
            // Transfer the panda to the highest bidder
            eipandas.safeTransferFrom(address(this), _auction.highestBidder, _auction.pandaId);
            emit AuctionSettled(_auction.pandaId, _auction.highestBidder, _auction.highestBid);

            // TODO:
            // withdraw the stETH from lido contract
            // will need to do an approve first - from stETH to lido withdraw contract

            // then withdraw - calling requestWithdrawals on lido contract
            // then transfer the stETH to the highest bidder - we will need the requestId for this?

        }

        auctionInProgress = false;
    }
}
