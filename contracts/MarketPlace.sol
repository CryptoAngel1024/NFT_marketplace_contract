// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface GiveTreeNft {
    function partnerRoyaltyOf(uint tokenId) 
        external view 
        returns (address, uint);
}

contract MarketPlace is Ownable, ReentrancyGuard {
   using SafeMath for uint256;

   event CreatedAuction(
        uint256 saleId,
        address indexed wallet,
        address indexed nftContractAddress,
        uint256 tokenId,
        uint256 created
    );
    event CanceledAuction(
        uint256 indexed saleId,
        address indexed wallet,
        uint256 created
    );
    event NewHighestOffer(
        uint256 indexed saleId,
        address indexed wallet,
        uint256 amount,
        uint256 created
    );
    event DirectBought(
        uint256 indexed saleId,
        address indexed wallet,
        address indexed nftContractAddress,
        uint256 tokenId,
        uint256 amount,
        uint256 created
    );
    event Claimed(
        uint256 indexed saleId,
        address indexed wallet,
        address indexed nftContractAddress,
        uint256 tokenId,
        uint256 amount,
        uint256 created
    );

    event NewSaleIdCreated(
        uint256 indexed saleId,
        address indexed wallet,
        address tokenAddress,
        uint256 tokenId,
        uint256 created
    );

    event SaleCXL(
        uint256 indexed saleId,
        address indexed wallet,
        address tokenAddress,
        uint256 tokenId,
        uint256 created
    );

    event Refunded(
        uint256 indexed saleId,
        address indexed sellersWallet,
        address buyerWallet,
        uint256 created
    );

    struct Royalty {
        address wallet;
        uint fee;
    }

    struct Sale {
        address nftContractAddress;
        uint256 tokenId;
        address owner;
        bool isAuction;
        uint256 minPrice;
        uint256 fixedPrice;
        uint256 endDate;
        bool royalty;
        bool paymentClaimed;
        bool royaltyClaimed;
        uint256 finalPrice;
        bool refunded;
    }

    struct Offer {
        address buyer;
        uint256 offer;
        uint256 date;
    }

    Royalty public giveTree;
    Royalty public giveTreeDao;

    uint256 public salesCount;
    bool public marketLive = true;

    mapping(uint256 => bool) public claimedAuctions;
    mapping(uint256 => Offer) public highestOffers;
    mapping(uint256 => Offer[]) public offersArr;
    mapping(address => mapping(uint256 => uint256)) public lastAuctionByTokenByContract;
    mapping(address => mapping(uint256 => Royalty)) public royaltiesByTokenByContract;
    mapping(uint256 => Sale) public sales;
    mapping(address => mapping(uint256 => uint256)) public lastSaleByToken;
    mapping(uint256 => address) public buyerBySaleId;
    mapping(address => mapping(uint256 => uint256)) public offersEscrow;

    constructor(address _giveTree, uint _giveTreeFee, address _giveTreeDao, uint _giveTreeDaoFee) payable {
        require(
            address(_giveTree) != address(0) && _giveTreeDao != address(0)
        );
        giveTree = Royalty ({
          wallet: _giveTree,
          fee: _giveTreeFee
        });
        giveTreeDao = Royalty ({
          wallet: _giveTreeDao,
          fee: _giveTreeDaoFee
        });
    }

    function setGiveTree(address _giveTree, uint _giveTreeFee) external onlyOwner {
        giveTree = Royalty ({
          wallet: _giveTree,
          fee: _giveTreeFee
        });
    }

    function setGiveTreeDao(address _giveTreeDao, uint _giveTreeDaoFee) external onlyOwner {
        giveTreeDao = Royalty ({
          wallet: _giveTreeDao,
          fee: _giveTreeDaoFee
        });
    }

    function createAuction(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _minPrice,
        uint256 _fixedPrice,
        uint256 _duration
    )
        external
        payable
        returns (uint256)
    {
        require(marketLive, "Market closed");

        // Transfer NFT into
        IERC721(_nftContractAddress).transferFrom(
            msg.sender,
            address(this),
            _tokenId
        );

        uint256 timeNow = _getTime();
        uint256 newAuction = salesCount;
        salesCount += 1;

        sales[newAuction] = Sale({
            nftContractAddress: _nftContractAddress,
            tokenId: _tokenId,
            owner: msg.sender,
            isAuction: true,
            minPrice: _minPrice,
            fixedPrice: _fixedPrice,
            royalty: royaltiesByTokenByContract[_nftContractAddress][_tokenId].wallet != address(0),
            endDate: timeNow + _duration,
            paymentClaimed: false,
            royaltyClaimed: false,
            finalPrice: 0,
            refunded: false
        });

        lastAuctionByTokenByContract[_nftContractAddress][_tokenId] = newAuction;

        if (royaltiesByTokenByContract[_nftContractAddress][_tokenId].wallet == address(0)) {
            setRoyaltyForToken(_nftContractAddress, _tokenId);
        }
        emit CreatedAuction(
            newAuction,
            msg.sender,
            _nftContractAddress,
            _tokenId,
            timeNow
        );

        return newAuction;
    }

    function participateAuction(uint256 _auctionId)
        external
        payable
        nonReentrant
        inProgress(_auctionId)
        minPrice(_auctionId, msg.value)
        newHighestOffer(_auctionId, msg.value)
    {
        require(marketLive, "Market closed");
        require(sales[_auctionId].isAuction, "Not an auction");
        //offersEscrow[msg.sender][_auctionId] = msg.value;

        _returnPreviousOffer(_auctionId);

        uint256 timeNow = _getTime();
        highestOffers[_auctionId] = Offer({
            buyer: msg.sender,
            offer: msg.value,
            date: timeNow
        });

        emit NewHighestOffer(_auctionId, msg.sender, msg.value, timeNow);
    }

    function directBuy(uint256 _auctionId)
        public
        payable
        nonReentrant
        notClaimed(_auctionId)
        inProgress(_auctionId)
    {
        require(marketLive, "Market closed");
        require(msg.value > sales[_auctionId].fixedPrice, "Not enough balance");
        require(sales[_auctionId].fixedPrice > 0, "Direct buy unavailable");
        sales[_auctionId].finalPrice = sales[_auctionId].fixedPrice;
        buyerBySaleId[_auctionId] = msg.sender;

        processPayment(
            _auctionId,
            sales[_auctionId].nftContractAddress,
            sales[_auctionId].tokenId,
            sales[_auctionId].owner,
            sales[_auctionId].fixedPrice,
            msg.sender
        );

        //2. Send NFT to winner
        address nftholder = sales[_auctionId].owner;
        if (sales[_auctionId].isAuction) {
            nftholder = address(this);
        }

        IERC721(sales[_auctionId].nftContractAddress).transferFrom(
            nftholder,
            msg.sender,
            sales[_auctionId].tokenId
        );

        uint256 timeNow = _getTime();
        sales[_auctionId].finalPrice = sales[_auctionId].fixedPrice;
        claimedAuctions[_auctionId] = true;
        _returnPreviousOffer(_auctionId);

        emit DirectBought(
            _auctionId,
            msg.sender,
            sales[_auctionId].nftContractAddress,
            sales[_auctionId].tokenId,
            sales[_auctionId].fixedPrice,
            timeNow
        );
    }

    function processPayment(
        uint256 saleId,
        address nftContractAddress,
        uint256 tokenId,
        address seller,
        uint256 grossAmount,
        address senderOfPayment
    ) internal {
        Royalty memory partnerRoyalty = royaltiesByTokenByContract[nftContractAddress][tokenId];
        uint256 giveTreeFee = sales[saleId].fixedPrice.mul(giveTree.fee).div(100);
        uint256 giveTreeDaoFee = sales[saleId].fixedPrice.mul(giveTreeDao.fee).div(100);
        uint256 partnerFee = sales[saleId].fixedPrice.mul(partnerRoyalty.fee).div(100);
        // 1. SEND royalties 

        (bool sent,) = giveTree.wallet.call{value: giveTreeFee}("");
        require(sent, "Failed to send Ether");

        (bool sent1,) = giveTreeDao.wallet.call{value: giveTreeDaoFee}("");
        require(sent1, "Failed to send Ether");

        (bool sent2,) = partnerRoyalty.wallet.call{value: partnerFee}("");
        require(sent2, "Failed to send Ether");

        uint256 netAmount = grossAmount.sub(giveTreeFee).sub(giveTreeDaoFee).sub(partnerFee);
        (bool sent3,) = seller.call{value: netAmount}("");
        require(sent3, "Failed to send Ether");
    }
    
    /**
     * @dev Winner user claims NFT for ended auction.
     */
    function claim(uint256 _auctionId)
        external
        nonReentrant
        ended(_auctionId)
        notClaimed(_auctionId)
    {
        require(highestOffers[_auctionId].buyer != address(0x0), "No bids");

        uint256 timeNow = _getTime();
        sales[_auctionId].finalPrice = highestOffers[_auctionId].offer;
        buyerBySaleId[_auctionId] = msg.sender;

        processPayment(
            _auctionId,
            sales[_auctionId].nftContractAddress,
            sales[_auctionId].tokenId,
            sales[_auctionId].owner,
            highestOffers[_auctionId].offer,
            address(this)
        );

        // Transfer NFT to new Owner
        IERC721(sales[_auctionId].nftContractAddress).transferFrom(
            address(this),
            highestOffers[_auctionId].buyer,
            sales[_auctionId].tokenId
        );

        claimedAuctions[_auctionId] = true;

        emit Claimed(
            _auctionId,
            highestOffers[_auctionId].buyer,
            sales[_auctionId].nftContractAddress,
            sales[_auctionId].tokenId,
            highestOffers[_auctionId].offer,
            timeNow
        );
    }

    /**
     * @dev Cancel auction and returns token.
     */
    function cancelAuction(uint256 _auctionId) external nonReentrant {
        require(
            sales[_auctionId].owner == msg.sender || msg.sender == owner(),
            "GiveTreeAuction: User is not the token owner"
        );
        require(highestOffers[_auctionId].buyer == address(0x0), "Has bids");
        require(sales[_auctionId].finalPrice == 0, "Already bought");

        uint256 timeNow = _getTime();

        sales[_auctionId].endDate = timeNow;

        IERC721(sales[_auctionId].nftContractAddress).transferFrom(
            address(this),
            sales[_auctionId].owner,
            sales[_auctionId].tokenId
        );

        emit CanceledAuction(_auctionId, msg.sender, timeNow);
    }

    function cancelSale(uint256 _saleId) public inProgress(_saleId) {
        require(
            IERC721(sales[_saleId].nftContractAddress).ownerOf(
                sales[_saleId].tokenId
            ) ==
                msg.sender ||
                msg.sender == owner(),
            "Not Owner"
        );
        uint256 timeNow = _getTime();
        sales[_saleId].endDate = timeNow;

        emit SaleCXL(
            _saleId,
            msg.sender,
            sales[_saleId].nftContractAddress,
            sales[_saleId].tokenId,
            timeNow
        );
    }


    function setRoyaltyForToken(
        address nftContractAddress,
        uint256 _tokenId,
    ) internal {
        require(
            address(this) == IERC721(nftContractAddress).ownerOf(_tokenId), "Not the owner"
        );
        require(
            lastAuctionByTokenByContract[nftContractAddress][_tokenId] == 0 &&
                lastSaleByToken[nftContractAddress][_tokenId] == 0,
            "Market already set"
        );
        require(
            royaltiesByTokenByContract[nftContractAddress][_tokenId].wallet ==
                address(0),
            "Royalty already set"
        );
        (address wallet, uint fee) = GiveTreeNft(nftContractAddress).partnerRoyaltyOf(_tokenId);
        royaltiesByTokenByContract[nftContractAddress][_tokenId] = Royalty({
            wallet: wallet,
            fee: fee
        });
    }

    function refund(uint256 saleId) external nonReentrant onlyOwner {
        require(!sales[saleId].paymentClaimed, "Payment Already Claimed");
        require(sales[saleId].finalPrice > 0, "No Sale Made");
        require(buyerBySaleId[saleId] != address(0), "No Buyer");
 
        (bool sent,) = buyerBySaleId[saleId].call{value: sales[saleId].finalPrice}("");
        require(sent, "Failed to send Ether");

        uint256 timeNow = _getTime();
        emit Refunded(
            saleId,
            sales[saleId].owner,
            buyerBySaleId[saleId],
            timeNow
        );
    }

    function setMarketStatus(bool _marketLive) external onlyOwner {
        marketLive = _marketLive;
    }

    /******************
    PRIVATE FUNCTIONS
    *******************/
    function _returnPreviousOffer(uint256 _auctionId) internal {
        Offer memory currentOffer = highestOffers[_auctionId];
        if (currentOffer.offer > 0) {

            (bool sent,) = currentOffer.buyer.call{value: currentOffer.offer}("");
            require(sent, "Failed to send Ether");
        }
    }

    function _getTime() internal view returns (uint256) {
        return block.timestamp;
    }


    modifier newHighestOffer(uint256 _auctionId, uint256 value) {
        require(
            value > highestOffers[_auctionId].offer,
            "GiveTreeAuction: Amount must be higher"
        );
        _;
    }

    modifier minPrice(uint256 _auctionId, uint256 value) {
        require(
            value >= sales[_auctionId].minPrice,
            "GiveTreeAuction: Insufficient offer amount for this auction"
        );
        _;
    }

    modifier inProgress(uint256 _auctionId) {
        require(
            (sales[_auctionId].endDate > _getTime()) &&
                sales[_auctionId].finalPrice == 0,
            "GiveTreeAuction: Auction closed"
        );
        _;
    }

    modifier ended(uint256 _auctionId) {
        require(
            (_getTime() > sales[_auctionId].endDate) &&
                sales[_auctionId].finalPrice == 0,
            "GiveTreeAuction: Auction not closed"
        );
        _;
    }


}