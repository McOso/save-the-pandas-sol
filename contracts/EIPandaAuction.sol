// SPDX-License-Identifier: MIT

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

pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract EIPandaAuction is ReentrancyGuard, Ownable {
  struct Auction {
    uint256 tokenId;
    uint256 endTime;
    uint256 highestBid;
    address highestBidder;
  }

  IERC721 public eipandas;
  IERC20 public lidoStETH;
  uint256 public constant RESERVE_PRICE = 0.01 ether;
  Auction public currentAuction;
  bool public auctionInProgress;

  // The minimum percentage difference between the last bid amount and the current bid
  uint8 public minBidIncrementPercentage;

  event PandaDeposited(uint256 tokenId);
  event AuctionStarted(uint256 tokenId, uint256 endTime);
  event AuctionSuccessful(uint256 tokenId, address indexed buyer, uint256 totalPrice);
  event PandaKilled(uint256 tokenId);

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

  function depositPanda(uint256 tokenId) external nonReentrant {
    require(eipandas.ownerOf(tokenId) == msg.sender, "Ser, this is not your panda");

    eipandas.safeTransferFrom(msg.sender, address(this), tokenId);
    emit PandaDeposited(tokenId);
  }

  function startAuction(uint256 tokenId) external nonReentrant noActiveAuction {
    require(eipandas.ownerOf(tokenId) == address(this), "Token not deposited");

    uint256 auctionEndTime = block.timestamp + 1 days;
    currentAuction = Auction({
      tokenId: tokenId,
      endTime: auctionEndTime,
      highestBidder: address(0),
      highestBid: 0
    });

    auctionInProgress = true;

    emit AuctionStarted(tokenId, auctionEndTime);
  }

  function placeBid(uint256 bidAmount) external nonReentrant activeAuction {
    require(block.timestamp < currentAuction.endTime, "Auction has ended");
    require(bidAmount >= RESERVE_PRICE, "Bid amount less than reserve");
    require(bidAmount > currentAuction.highestBid, "Bid amount less than current bid");

    // Transfer the stETH tokens from the bidder to the contract
    lidoStETH.transferFrom(msg.sender, address(this), bidAmount);

    if (currentAuction.highestBidder != address(0)) {
      // Transfer the previous highest bid back to the bidder
      lidoStETH.transfer(currentAuction.highestBidder, currentAuction.highestBid);
    }

    currentAuction.highestBid = bidAmount;
    currentAuction.highestBidder = msg.sender;
  }

  function endAuction() external nonReentrant activeAuction {
    require(block.timestamp >= currentAuction.endTime, "Auction not yet ended");

    if (currentAuction.highestBid >= RESERVE_PRICE) {
      // Transfer the token to the highest bidder
      eipandas.safeTransferFrom(
        address(this),
        currentAuction.highestBidder,
        currentAuction.tokenId
      );
      emit AuctionSuccessful(
        currentAuction.tokenId,
        currentAuction.highestBidder,
        currentAuction.highestBid
      );
    } else {
      // R.I.P.
      eipandas.safeTransferFrom(
        address(this),
        address(0x000000000000000000000000000000000000dEaD),
        currentAuction.tokenId
      );
      emit PandaKilled(currentAuction.tokenId);
    }

    // Clear auction details
    delete currentAuction;
    auctionInProgress = false;
  }

  function withdrawStETH() external nonReentrant onlyOwner {
    uint256 stethBalance = lidoStETH.balanceOf(address(this));
    lidoStETH.transfer(owner(), stethBalance);
  }
}
