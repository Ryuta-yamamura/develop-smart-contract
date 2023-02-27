// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

// ERC721規格の使用(Using ERC721 standard)
// 利用できる機能(Functionality we can use)
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
//prevents re-entrancy attacks
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/PullPayment.sol";
import "hardhat/console.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


contract NFTMarketplace is ERC721URIStorage, PullPayment, Ownable, ReentrancyGuard {
    // カウンターユーティリティを使用
    using Counters for Counters.Counter;
    using SafeERC20 for IERC20;
    Counters.Counter private _itemIds;
    Counters.Counter private _itemsSold;
    Counters.Counter private _tokenIds;

    uint256 listingPrice = 0.005 ether;
    uint256 secondListingPrice = 0.010 ether;

    // DAOトークンの設定
    address public daoToken = address(0);
    uint256 public sellNFTReward = 10;
    uint256 public buyNFTReward = 1;

    // マーケットアドレス所有者の販売時のパーセンテージを追加
    uint256 ownerCommissionPercentage = 50;
    uint256 creatorCommissionPercentage = 100;
    uint256 sellerCommissionPercentage = 1000 - ownerCommissionPercentage - creatorCommissionPercentage;

    struct NFTItem {
      uint256 tokenId;
      address payable owner;
      bool list;
    }

    struct MarketItem {
      uint256 itemId;
      address nftContract;
      uint256 tokenId;
      address payable seller;
      address payable owner;
      address payable creator;
      uint256 price;
      uint256 reserved;
      uint256 listTime;
      uint256 duration;
      SaleKind salekind;
      bool sold;
    }

    // 入札を設計
    struct Bid {
      uint256 bidTime;
      address bidder;
      uint256 value;
    }

    mapping(uint256 => NFTItem) private idToNFTItem;
    mapping(uint256 => MarketItem) private idToMarketItem;
    mapping(uint256 => Bid) public bids;
    mapping(address => mapping(uint256 => bool)) public blacklist;


    event MarketItemCreated (
      uint256 indexed itemId,
      address indexed nftContract,
      uint256 indexed tokenId,
      address seller,
      address owner,
      address creator,
      uint256 price,
      uint256 reserved,
      uint256 listTime,
      uint256 duration,
      SaleKind salekind,
      bool sold

    );

    event MarketItemSold (
      address indexed nftContract,
      uint256 indexed tokenId,
      address seller,
      address buyer,
      uint256 price
    );

    event Prohibited (
      address indexed nftContract,
      uint256 indexed tokenId
    );
    event CancellProhibited (
      address indexed nftContract,
      uint256 indexed tokenId
    );

    constructor()  ERC721("NFTs made for PhonoGraph", "PHG") {
    }

    // 販売方法の設定
    enum SaleKind { Fix, Auction }

    // オーナーへの成果報酬を取得
    function getOwnerShare(uint256 x) private view returns(uint256) {
        return (x / 1000) * ownerCommissionPercentage;
    }
    // クリエイターへの成果報酬を取得
    function getCreatorShare(uint256 x) private view returns(uint256) {
      return (x / 1000) * creatorCommissionPercentage;
    }
    // 販売者への成果報酬を取得
    function getSellerShare(uint256 x) private view returns(uint256) {
      return (x / 1000) * sellerCommissionPercentage;
    }


    /* 契約のオーナーへの報酬率を更新 */
    function updateOwnerCommissionPercentage(uint _ownerCommissionPercentage) public payable onlyOwner{

        ownerCommissionPercentage = _ownerCommissionPercentage;
    }

        /* 契約のクリエイターへの報酬率を更新 */
    function updateCreatorCommissionPercentage(uint _creatorCommissionPercentage) public payable onlyOwner{

        creatorCommissionPercentage = _creatorCommissionPercentage;
    }

    
    /* 契約のオーナーへの報酬率を取得*/
    function getOwnerCommissionPercentage() public view returns (uint256) {
      return ownerCommissionPercentage;
    }
    /* 契約のクリエイターへの報酬率を取得*/
    function getCreatorCommissionPercentage() public view returns (uint256) {
      return creatorCommissionPercentage;
    }

    /* 契約のリスト価格を更新 */
    function updateListingPrice(uint _listingPrice) public payable onlyOwner{
      listingPrice = _listingPrice;
    }
    function updateSecondListingPrice(uint _listingPrice) public payable onlyOwner{
      secondListingPrice = _listingPrice;
    }

    // NFTのブラックリストを追加
    function addBlackNFT(address nftaddress, uint256 tokenId) public onlyOwner{
      blacklist[nftaddress][tokenId] = true;
      emit Prohibited(nftaddress,tokenId);
    }

    // NFTのブラックリストをキャンセル
    function cancelBlackNFT(address nftaddress, uint256 tokenId) public onlyOwner{
      blacklist[nftaddress][tokenId] = false;
      emit CancellProhibited(nftaddress,tokenId);
    }

    // DAOトークンの報酬内容を変更
    function setReward(uint256 _sellNFTReward, uint256 _buyNFTReward) public onlyOwner{
      sellNFTReward = _sellNFTReward;
      buyNFTReward = _buyNFTReward;
    }


    function transferETH(address receipt, uint256 amount) public onlyOwner{
      payable(receipt).transfer(amount);
    }
    function withdrawETH(address wallet) public onlyOwner{
      payable(wallet).transfer(address(this).balance);
    }
    function transferERC20Token(IERC20 _tokenContract, address _to, uint256 _amount) public onlyOwner {
        _tokenContract.safeTransfer(_to, _amount);
    }
    function getNftItembytokenId(uint256 tokenId) public view returns (NFTItem memory) {
      return idToNFTItem[tokenId];
    }

    function getNftInfobyMarketItemId(uint256 marketItemId) public view returns (MarketItem memory) {
      return idToMarketItem[marketItemId];
    }



    function getListingPrice() public view returns (uint256[2] memory) {
      return [listingPrice, secondListingPrice];
    }

    function mintTokenAndApprove(string memory tokenURI) public returns (uint) {
        _tokenIds.increment();
        uint256 tokenId = _tokenIds.current();

        _mint(msg.sender, tokenId);
        _setTokenURI(tokenId, tokenURI);
        idToNFTItem[tokenId] = NFTItem(
            tokenId,
            payable(msg.sender),
            false
        );

        setApprovalForAll(address(this), true);
        return tokenId;
    }

    function mintToken(string memory tokenURI) public returns (uint) {
        _tokenIds.increment();
        uint256 tokenId = _tokenIds.current();

        _mint(msg.sender, tokenId);
        _setTokenURI(tokenId, tokenURI);
        idToNFTItem[tokenId] = NFTItem(
            tokenId,
            payable(msg.sender),
            false
        );
        return tokenId;
    }


    function sellNFTInMarket(
      address nftContract,
      uint256 tokenId,
      SaleKind salekind,
      uint256 price,
      uint256 reserved,
      uint256 duration
    ) public payable nonReentrant {
      require(!blacklist[nftContract][0], "the whole nft contract is prohibited");
      require(!blacklist[nftContract][tokenId], "the nft is prohibited");
      require(price > 0, "price needed");
      require(reserved == 0 || reserved > price, "reserved must be here when auction");
      require(msg.value == listingPrice, "listing price needed");
      require(IERC721(nftContract).ownerOf(tokenId) == msg.sender, "not owner of the token");

      _itemIds.increment();
      // 販売方法が定額の場合は金額、オークションの場合は予定金額をセット
      uint256 reservedtmp = salekind == SaleKind.Fix? price : reserved;
      uint256 listTime = block.timestamp;
      idToMarketItem[_itemIds.current()] =  MarketItem(
        _itemIds.current(),
        nftContract,
        tokenId,
        payable(msg.sender),
        payable(address(this)),
        payable(msg.sender),
        price,
        reservedtmp,
        listTime,
        duration,
        salekind,
        false
      );
      idToNFTItem[tokenId].list = true;
        
        _asyncTransfer(owner(),msg.value);
        withdrawPayments(payable(owner()));

      IERC721(nftContract).transferFrom(msg.sender, address(this), tokenId);

    }
    function createAndsellNFTInMarket(
      string memory tokenURI,
      address nftContract,
      SaleKind salekind,
      uint256 price,
      uint256 reserved,
      uint256 duration
    ) public payable nonReentrant {
      require(price > 0, "price needed");
      require(reserved == 0 || reserved > price, "reserved must be here when auction");
      // NFTを作成
      _tokenIds.increment();
      uint256 tokenId = _tokenIds.current();
      _mint(msg.sender, tokenId);
      _setTokenURI(tokenId, tokenURI);
      
      idToNFTItem[tokenId] = NFTItem(
          tokenId,
          payable(msg.sender),
          true
      );
      setApprovalForAll(address(this), true);
      _itemIds.increment();
      // 販売方法が定額の場合は金額、オークションの場合は予定金額をセット
      uint256 reservedtmp = salekind == SaleKind.Fix? price : reserved;
      uint256 listTime = block.timestamp;
      idToMarketItem[_itemIds.current()] =  MarketItem(
        _itemIds.current(),
        nftContract,
        tokenId,
        payable(msg.sender),
        payable(address(this)),
        payable(msg.sender),
        price,
        reservedtmp,
        listTime,
        duration,
        salekind,
        false
      );        
        _asyncTransfer(owner(),msg.value);
        withdrawPayments(payable(owner()));
      IERC721(nftContract).transferFrom(msg.sender, address(this), tokenId);

    }

    /* 購入したトークンを転売 */
    function resellToken(
      uint256 itemId,
      address nftContract,
      uint256 tokenId,
      SaleKind salekind,
      uint256 price,
      uint256 reserved,
      uint256 duration
    ) public payable nonReentrant{
      require(!blacklist[nftContract][0], "the whole nft contract is prohibited");
      require(!blacklist[nftContract][tokenId], "the nft is prohibited");
      require(price > 0, "price needed");
      require(reserved == 0 || reserved > price, "Price must be at least 1 wei");
      require(idToMarketItem[itemId].nftContract == nftContract, "contract not match");
      require(idToMarketItem[itemId].tokenId == tokenId, "contract not match");
      require(nftContract != address(0), "no such item");
      require(IERC721(nftContract).ownerOf(tokenId) == msg.sender, "not owner of the token");
      require(idToMarketItem[itemId].owner == msg.sender || (idToMarketItem[itemId].owner == address(this) && idToMarketItem[itemId].seller == msg.sender), "can not sell by sender");
      require(msg.value == secondListingPrice, "Price must be equal to listing price");

      // 販売方法が定額の場合は金額、オークションの場合は予定金額をセット
      uint256 reservedtmp = salekind == SaleKind.Fix ? price : reserved;
      uint256 listTime = block.timestamp;
      address creator = idToMarketItem[itemId].creator;

      // マーケットアイテム情報の更新
      idToMarketItem[itemId].seller = payable(msg.sender);
      idToMarketItem[itemId].owner = payable(address(this));
      idToMarketItem[itemId].price = price;
      idToMarketItem[itemId].reserved = reservedtmp;
      idToMarketItem[itemId].listTime = listTime;
      idToMarketItem[itemId].duration = duration;
      idToMarketItem[itemId].salekind = salekind;
      idToMarketItem[itemId].sold = false;

      _itemsSold.decrement();

      _asyncTransfer(owner(),msg.value);
      withdrawPayments(payable(owner()));

      IERC721(nftContract).transferFrom(msg.sender, address(this), itemId);

      // itemIdの入札情報を削除
      delete bids[itemId];


    }

    function buyNftbyMarketItemId(
      uint256 itemId
    ) public payable nonReentrant {
      uint256 price = idToMarketItem[itemId].price;
      uint256 tokenId = idToMarketItem[itemId].tokenId;
      address nftContract = idToMarketItem[itemId].nftContract;
      uint256 endtime = idToMarketItem[itemId].listTime + idToMarketItem[itemId].duration * 60;
      uint256 reserved = idToMarketItem[itemId].reserved;
      // クリエイターのaddress
      address payable creator = idToMarketItem[itemId].creator;
      // 販売者のaddress
      address payable seller = idToMarketItem[itemId].seller;

      require(!blacklist[nftContract][0], "the whole nft contract is prohibited");
      require(!blacklist[nftContract][tokenId], "the nft is prohibited");
      require(nftContract != address(0), "no such item");
      require(block.timestamp >= idToMarketItem[itemId].listTime, "sale not yet start");
      require(idToMarketItem[itemId].owner == address(this), "had sold");

      // 定額販売の決済方法について確認
      if(SaleKind.Fix == idToMarketItem[itemId].salekind){
        require(msg.value == price, "price not right");
        require(block.timestamp < endtime , "sale had ended");
        // 金額の分配を実施
        _asyncTransfer(owner(), getOwnerShare(msg.value));
        _asyncTransfer(creator, getCreatorShare(msg.value));
        _asyncTransfer(seller, getSellerShare(msg.value));
        withdrawPayments(payable(owner()));
        withdrawPayments(creator);
        withdrawPayments(seller);

        idToMarketItem[itemId].owner = payable(msg.sender);
        idToMarketItem[itemId].sold = true;
        idToMarketItem[itemId].seller = payable(address(0));
        _itemsSold.increment();

        // イベントの発火
        emit MarketItemSold(
          nftContract,
          itemId,
          idToMarketItem[itemId].seller,
          idToMarketItem[itemId].owner,
          price
        );

        

        
        // NFT の所有権を売り手から買い手に譲渡します。
        IERC721(nftContract).transferFrom(address(this), msg.sender, itemId);

      // ここからはオークションの設定
      }else{
        // 現在時刻がオークション終了より前の場合、入札情報の更新を実施
        if(block.timestamp < endtime){
          require(msg.value >= price, "price not right");
          // 前回の入札者に対して入札額を返却
          if(bids[itemId].value != 0){
            //return value
            require(msg.value > bids[itemId].value , "below bid price");
            payable(bids[itemId].bidder).transfer(bids[itemId].value);
          }

          bids[itemId] = Bid(block.timestamp, msg.sender, msg.value);

          // 入札最大金額より多くの金額を設定した場合、即時購入を実施
          if(reserved != 0 && msg.value >= reserved){
            // 金額の分配を実施
            _asyncTransfer(owner(), getOwnerShare(reserved));
            _asyncTransfer(creator, getCreatorShare(reserved));
            _asyncTransfer(seller, getSellerShare(reserved));
            withdrawPayments(payable(owner()));
            withdrawPayments(creator);
            withdrawPayments(seller);

            idToMarketItem[itemId].owner = payable(msg.sender);
            idToMarketItem[itemId].sold = true;
            idToMarketItem[itemId].seller = payable(address(0));
            _itemsSold.increment();

            emit MarketItemSold(
              nftContract,
              tokenId,
              idToMarketItem[itemId].seller,
              idToMarketItem[itemId].owner,
              msg.value
            );

            //distrubute dao token to buyer
            // DAOToken(daoToken).mint(msg.sender, buyNFTReward);

            if(msg.value-reserved > 0){
              payable(msg.sender).transfer(msg.value-reserved);
            }
            bids[itemId] = Bid(block.timestamp, msg.sender, reserved);
            // NFT の所有権を売り手から買い手に譲渡します。
            IERC721(nftContract).transferFrom(address(this), msg.sender, tokenId);
          }
        // オークション終了の場合sellerが取引を締結するように設計
        }else{
          if(bids[itemId].value != 0){
            // ここは販売者じゃなくても大丈夫かも
            require(msg.sender == seller, "Can only be operated by sellers");
            // 金額の分配を実施
            _asyncTransfer(owner(), getOwnerShare(bids[itemId].value));
            _asyncTransfer(creator, getCreatorShare(bids[itemId].value));
            _asyncTransfer(seller, getSellerShare(bids[itemId].value));
            withdrawPayments(payable(owner()));
            withdrawPayments(creator);
            withdrawPayments(seller);

            idToMarketItem[itemId].owner = payable(bids[itemId].bidder);
            idToMarketItem[itemId].sold = true;
            idToMarketItem[itemId].seller = payable(address(0));
            _itemsSold.increment();

            emit MarketItemSold(
              nftContract,
              itemId,
              idToMarketItem[itemId].seller,
              idToMarketItem[itemId].owner,
              bids[itemId].value
            );
            //distrubute dao token to buyer
            // DAOToken(daoToken).mint(msg.sender, buyNFTReward);

            // NFT の所有権を売り手から買い手に譲渡します。
            IERC721(nftContract).transferFrom(address(this), bids[itemId].bidder, itemId);
          }

          //no need eth for withdraw
          if(msg.value > 0){
            payable(msg.sender).transfer(msg.value);
          }
        }
      }

    }

    /* 売れ残ったマーケットアイテムをすべて返します(Returns all unsold market items) */
    function fetchMarketItems() public view returns (MarketItem[] memory) {
      uint itemCount = _itemIds.current();
      uint unsoldItemCount = _itemIds.current() - _itemsSold.current();
      uint currentIndex = 0;

      MarketItem[] memory items = new MarketItem[](unsoldItemCount);
      for (uint i = 0; i < itemCount; i++) {
        if (idToMarketItem[i + 1].owner == address(this) && idToMarketItem[i + 1].nftContract != address(0)) {
          uint currentId = idToMarketItem[i + 1].itemId;
          MarketItem storage currentItem = idToMarketItem[currentId];
          items[currentIndex] = currentItem;
          currentIndex += 1;
        }
      }

      return items;
    }

    /* ユーザーが購入した商品のみを返す(Returns only items that a user has purchased) */
    function fetchMyNFTs() public view returns (MarketItem[] memory) {
      uint256 totalItemCount = _itemIds.current();
      uint256 itemCount = 0;
      uint256 currentIndex = 0;

      for (uint256 i = 0; i < totalItemCount; i++) {
        if (idToMarketItem[i + 1].owner == msg.sender) {
          itemCount += 1;
        }
      }

      MarketItem[] memory items = new MarketItem[](itemCount);
      for (uint256 i = 0; i < totalItemCount; i++) {
        if (idToMarketItem[i + 1].owner == msg.sender) {
          uint256 currentId = idToMarketItem[i + 1].itemId;
          MarketItem storage currentItem = idToMarketItem[currentId];
          items[currentIndex] = currentItem;
          currentIndex += 1;
        }
      }
      return items;
    }

    /* ユーザーがリストした項目のみを返します(Returns only items a user has listed) */
    function fetchItemsListed() public view returns (MarketItem[] memory) {
      uint totalItemCount = _itemIds.current();
      uint itemCount = 0;
      uint currentIndex = 0;

      for (uint i = 0; i < totalItemCount; i++) {
        if (idToMarketItem[i + 1].seller == msg.sender) {
          itemCount += 1;
        }
      }

      MarketItem[] memory items = new MarketItem[](itemCount);
      for (uint i = 0; i < totalItemCount; i++) {
        if (idToMarketItem[i + 1].seller == msg.sender) {
          uint currentId = idToMarketItem[i + 1].itemId;
          MarketItem storage currentItem = idToMarketItem[currentId];
          items[currentIndex] = currentItem;
          currentIndex += 1;
        }
      }
      
      return items;
    }

    /* ユーザーが作成したまだリストしていないアイテムのみを返します */
    function fetchItemsNoListed() public view returns (NFTItem[] memory) {
      uint totalItemCount = _tokenIds.current();
      uint itemCount = 0;
      uint currentIndex = 0;

      for (uint i = 0; i < totalItemCount; i++) {
        if ((idToNFTItem[i + 1].owner == msg.sender) && (idToNFTItem[i + 1].list == false)) {
          itemCount += 1;
        }
      }

      NFTItem[] memory items = new NFTItem[](itemCount);
      for (uint i = 0; i < totalItemCount; i++) {
        if ((idToNFTItem[i + 1].owner == msg.sender) && (idToNFTItem[i + 1].list == false)) {
          uint currentId = idToNFTItem[i + 1].tokenId;
          NFTItem storage currentItem = idToNFTItem[currentId];
          items[currentIndex] = currentItem;
          currentIndex += 1;
        }
      }
      
      return items;
    }

}