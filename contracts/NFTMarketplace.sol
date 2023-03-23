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

// import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// import "./DAOToken.sol";


// public は、クライアント アプリケーションから利用可能
// viewは、トランザクション作業が発生しない(ガス代が0)
// contractという大きな入れ物を定義。ここに関数や変数を指定する。
// コントラクトの作成 ->ERC721URIStorage、Ownableから継承
contract NFTMarketplace is ERC721URIStorage, PullPayment, Ownable, ReentrancyGuard {
    // カウンターユーティリティを使用
    using Counters for Counters.Counter;
    // using SafeERC20 for IERC20;
    // 最初のトークンが発行されると値は2から始まり、2番目のトークンは2となる
    // 次に、カウンターを使用してトークン ID を1増やします
    Counters.Counter private _itemIds;
    Counters.Counter private _itemsSold;
    Counters.Counter private _tokenIds;

    // マーケットプレイスにnftをリストする手数料
    // リスト料金を請求します。
    uint256 private listingPrice = 0;
    // 2回目移行のリスト料金を変更します。
    uint256 private secondListingPrice = 5 ether;

    // DAOトークンの設定
    // address public daoToken = address(0);
    // uint256 public sellNFTReward = 10;
    // uint256 public buyNFTReward = 1;

    // マーケットアドレス所有者の販売時のパーセンテージを追加
    uint256 private ownerFirstCommissionPercentage = 250;
    uint256 private creatorFirstCommissionPercentage = 50;
    uint256 private sellerCommissionPercentage = 1000 - ownerFirstCommissionPercentage - creatorFirstCommissionPercentage;
    // ロイヤリティの最大パーセンテージ
    uint256 private maxRoyaltyPercentage = 150;
    

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
      uint256 startDuration;
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

    // クリエイターのロイヤリティを設定
    struct CreatorInfo {
      address creator;
      uint256 salesCount;
      uint256 royaltyPercentage;
    }

    // 作成されたすべてのアイテムの確認ができると
    // アイテム ID である整数が渡され、マーケット アイテムが返される。
    // マーケットアイテムを取得するには、アイテムIDのみが必要
    mapping(uint256 => NFTItem) private idToNFTItem;
    mapping(uint256 => MarketItem) private idToMarketItem;
    mapping(uint256 => Bid) public bids;
    mapping(address => mapping(uint256 => bool)) public blacklist;
    mapping(address => CreatorInfo) private creators;


    // 市場アイテムが作成されたときにイベントを発生させます(have an event for when a market item is created.)
    //このイベントはMarketItemに一致します (this event matches the MarketItem)
    event MarketItemCreated (
      MarketItem marketItem
    );

    event BidCreated (
      Bid bid
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

    event RoyaltyIncreased (
      address indexed creator,
      uint256 indexed salesCount,
      uint256 indexed royaltyPercentage
    );

    // DaoTokenについては現在開発中のため、後でセッティングを実行
    constructor()  ERC721("NFTs made for PhonoGraph", "PHG") {
    }

    // 販売方法の設定
    enum SaleKind { Fix, Auction }


    // 成果報酬を取得
    function getShare(uint256 x, uint256 y) private pure returns(uint256) {
        return x * ( y / 1000 );
    }


    /* 契約のオーナーへの報酬率を更新 */
    function updateOwnerFirstCommissionPercentage(uint _ownerFirstCommissionPercentage) public payable onlyOwner{

        ownerFirstCommissionPercentage = _ownerFirstCommissionPercentage;
    }

    function updateCreatorFirstCommissionPercentage(uint _creatorFirstCommissionPercentage) public payable onlyOwner{

        creatorFirstCommissionPercentage = _creatorFirstCommissionPercentage;
    }

        /* 契約のクリエイターへの最大報酬率を更新 */
    function updateMaxRoyaltyPercentage(uint _maxRoyaltyPercentage) public payable onlyOwner{
      require(_maxRoyaltyPercentage < ownerFirstCommissionPercentage, "max must lower than ownerCommision");
        maxRoyaltyPercentage = _maxRoyaltyPercentage;
    }

    
    /* 契約のオーナーへの報酬率を取得*/
    function getOwnerFirstCommissionPercentage() public view returns (uint256) {
      return ownerFirstCommissionPercentage;
    }
    /* 契約のクリエイターへの報酬率を取得*/
    function getCreatorFirstCommissionPercentage() public view returns (uint256) {
      return creatorFirstCommissionPercentage;
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
    // function setReward(uint256 _sellNFTReward, uint256 _buyNFTReward) public onlyOwner{
    //   sellNFTReward = _sellNFTReward;
    //   buyNFTReward = _buyNFTReward;
    // }


    // 不具合が発生した場合、受取人にETHを送信する
    function transferETH(address receipt, uint256 amount) public onlyOwner{
      payable(receipt).transfer(amount);
    }
    // 何かしらの理由でアドレス内の金額が残っている場合に全て引き出す関数
    function withdrawETH(address wallet) public onlyOwner{
      payable(wallet).transfer(address(this).balance);
    }
    // 不具合が発生した場合、受取人にERC20トークンを送信する
    // function transferERC20Token(IERC20 _tokenContract, address _to, uint256 _amount) public onlyOwner {
    //     _tokenContract.safeTransfer(_to, _amount);
    // }
    // マーケットアイテムの情報を取得
    function getNftItembytokenId(uint256 tokenId) public view returns (NFTItem memory) {
      return idToNFTItem[tokenId];
    }

    // 出品前のアイテムの情報を取得
    function getNftInfobyMarketItemId(uint256 marketItemId) public view returns (MarketItem memory) {
      return idToMarketItem[marketItemId];
    }



    /* 契約のリスト価格を返す */
    // コントラクトを展開するとき、フロントエンドでは、それをリストする金額がわからない
    // そのため、契約を呼び出してリスト価格を取得し、適切な金額の支払いを行っていることを確認します
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

        // 作成者が登録されていない場合は、デフォルト値で新しい作成者を登録します
        if (creators[msg.sender].creator == address(0)) {
            creators[msg.sender] = CreatorInfo(msg.sender, 0, 0);
        }

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

        // 作成者が登録されていない場合は、デフォルト値で新しい作成者を登録します
        if (creators[msg.sender].creator == address(0)) {
            creators[msg.sender] = CreatorInfo(msg.sender, 0, 0);
        }
        return tokenId;
    }


    function sellNFTInMarket(
      address nftContract,
      uint256 tokenId,
      SaleKind salekind,
      uint256 price,
      uint256 reserved,
      uint256 duration,
      uint256 startDuration
    ) public payable nonReentrant {
        // 特定の条件が必要です。この場合、価格は 0 よりも大きくなります
      require(!blacklist[nftContract][0], "the whole nft contract is prohibited");
      require(!blacklist[nftContract][tokenId], "the nft is prohibited");
      require(price > 0, "price needed");
      require(reserved == 0 || reserved > price, "reserved must be here when auction");
      // トランザクションで送信するユーザーが正しい金額で送信する必要があります
      require(msg.value == listingPrice, "listing price needed");
      require(IERC721(nftContract).ownerOf(tokenId) == msg.sender, "not owner of the token");

      _itemIds.increment();
      // 販売方法が定額の場合は金額、オークションの場合は予定金額をセット
      uint256 reservedtmp = salekind == SaleKind.Fix? price : reserved;
        // マーケット アイテムのマッピングを作成する
        // address(0)の支払人は所有者。
        // 売り手が市場に出す時は、所有者がいないため空のアドレスを入力
        // 最後の値は、販売可否のブール値です。まだ販売されていないので、それは false です。
      idToMarketItem[_itemIds.current()] =  MarketItem(
        _itemIds.current(),
        nftContract,
        tokenId,
        payable(msg.sender),
        payable(address(this)),
        payable(msg.sender),
        price,
        reservedtmp,
        block.timestamp,
        startDuration,
        duration,
        salekind,
        false
      );
      idToNFTItem[tokenId].list = true;
        
        // オーナーへのリスティングプライスをmapping
        _asyncTransfer(owner(),msg.value);
        withdrawPayments(payable(owner()));

        // nft の所有権をコントラクトに譲渡したい -> 次の購入者(we now want to transfer the ownership of the nft to the contract -> next buyer)
        // IERC721 で利用可能なメソッド(method available on IERC721)
      IERC721(nftContract).transferFrom(msg.sender, address(this), tokenId);
        // イベントの発火
      {
        emit MarketItemCreated(
          idToMarketItem[_itemIds.current()]
        );
      }
      //販売者にDAOトークンを発行
      // DAOToken(daoToken).mint(msg.sender, sellNFTReward);


    }
    function createAndsellNFTInMarket(
      string memory tokenURI,
      address nftContract,
      SaleKind salekind,
      uint256 price,
      uint256 reserved,
      uint256 duration,
      uint256 startDuration
    ) public payable nonReentrant {
        // 特定の条件が必要です。この場合、価格は 0 よりも大きくなります
      require(price > 0, "price needed");
      require(reserved == 0 || reserved > price, "reserved must be here when auction");
      // トランザクションで送信するユーザーが正しい金額で送信する必要があります
      require(msg.value == listingPrice, "listing price needed");
      // NFTを作成
      {
      _tokenIds.increment();
      _mint(msg.sender, _tokenIds.current());
      _setTokenURI(_tokenIds.current(), tokenURI);

      idToNFTItem[_tokenIds.current()] = NFTItem(
          _tokenIds.current(),
          payable(msg.sender),
          true
      );

      // 作成者が登録されていない場合は、デフォルト値で新しい作成者を登録します
      if (creators[msg.sender].creator == address(0)) {
          creators[msg.sender] = CreatorInfo(msg.sender, 0, 0);
      }

      setApprovalForAll(address(this), true);
      _itemIds.increment();

      // 販売方法が定額の場合は金額、オークションの場合は予定金額をセット
      uint256 reservedtmp = salekind == SaleKind.Fix? price : reserved;
        idToMarketItem[_itemIds.current()] =  MarketItem(
          _itemIds.current(),
          nftContract,
          _tokenIds.current(),
          payable(msg.sender),
          payable(address(this)),
          payable(msg.sender),
          price,
          reservedtmp,
          block.timestamp,
          startDuration,
          duration,
          salekind,
          false
        );        
      // オーナーへのリスティングプライスをmapping
      _asyncTransfer(owner(),msg.value);
      withdrawPayments(payable(owner()));
      IERC721(nftContract).transferFrom(msg.sender, address(this), _tokenIds.current());
        // イベントの発火
        emit MarketItemCreated(
          idToMarketItem[_itemIds.current()]
        );
      }
      //販売者にDAOトークンを発行
      // DAOToken(daoToken).mint(msg.sender, sellNFTReward);

    }

    /* 購入したトークンを転売 */
    function resellToken(
      uint256 itemId,
      address nftContract,
      uint256 tokenId,
      SaleKind salekind,
      uint256 price,
      uint256 reserved,
      uint256 duration,
      uint256 startDuration
    ) public payable nonReentrant{
      require(!blacklist[nftContract][0], "the whole nft contract is prohibited");
      require(!blacklist[nftContract][tokenId], "the nft is prohibited");
      require(price > 0, "price needed");
      require(reserved == 0 || reserved > price, "Price must be at least 1 wei");
      require(idToMarketItem[itemId].nftContract == nftContract, "contract not match");
      require(idToMarketItem[itemId].tokenId == tokenId, "contract not match");
      require(nftContract != address(0), "no such item");
      require(ownerOf(tokenId) == msg.sender, "not owner of the token");
      require(idToMarketItem[itemId].owner == msg.sender || (idToMarketItem[itemId].owner == address(this) && idToMarketItem[itemId].seller == msg.sender), "can not sell by sender");
      require(msg.value == secondListingPrice, "Price must be equal to listing price");

      // 販売方法が定額の場合は金額、オークションの場合は予定金額をセット
      uint256 reservedtmp = salekind == SaleKind.Fix ? price : reserved; //9

      // マーケットアイテム情報の更新
      idToMarketItem[itemId].seller = payable(msg.sender);
      idToMarketItem[itemId].owner = payable(address(this));
      idToMarketItem[itemId].price = price;
      idToMarketItem[itemId].reserved = reservedtmp;
      idToMarketItem[itemId].listTime = block.timestamp;
      idToMarketItem[itemId].startDuration = startDuration;
      idToMarketItem[itemId].duration = duration;
      idToMarketItem[itemId].salekind = salekind;
      idToMarketItem[itemId].sold = false;
      _itemsSold.decrement();

      _asyncTransfer(owner(),msg.value);
      withdrawPayments(payable(owner()));

      IERC721(nftContract).transferFrom(msg.sender, address(this), itemId);

      // itemIdの入札情報を削除
      delete bids[itemId];

            // イベントの発火
      emit MarketItemCreated(
        idToMarketItem[itemId]
      );
    }

    /* マーケットプレイス アイテムの販売を作成します(Creates the sale of a marketplace item) */
    /* 当事者間でアイテムの所有権と資金を譲渡します(Transfers ownership of the item, as well as funds between parties) */
    function buyNftbyMarketItemId(
      uint256 itemId
    ) public payable nonReentrant {
      uint256 price = idToMarketItem[itemId].price;
      uint256 tokenId = idToMarketItem[itemId].tokenId;
      address nftContract = idToMarketItem[itemId].nftContract;
      uint256 starttime = idToMarketItem[itemId].listTime + idToMarketItem[itemId].startDuration;
      uint256 endtime = idToMarketItem[itemId].listTime + idToMarketItem[itemId].startDuration + idToMarketItem[itemId].duration;
      uint256 reserved = idToMarketItem[itemId].reserved;
      // クリエイターのaddress
      address payable creator = idToMarketItem[itemId].creator;
      // 販売者のaddress
      address payable seller = idToMarketItem[itemId].seller;

      require(!blacklist[nftContract][0], "the whole nft contract is prohibited");
      require(!blacklist[nftContract][tokenId], "the nft is prohibited");
      require(nftContract != address(0), "no such item");
      require(block.timestamp >= starttime, "sale not yet start");
      require(idToMarketItem[itemId].owner == address(this), "had sold");

      // 定額販売の決済方法について確認
      if(SaleKind.Fix == idToMarketItem[itemId].salekind){
        require(msg.value == price, "price not right");
        // 金額の分配を実施
        // マーケットプレイスの手数料
        _asyncTransfer(owner(), getShare(msg.value, ownerFirstCommissionPercentage - creators[creator].royaltyPercentage));
        // クリエイター報酬
        _asyncTransfer(creator, getShare(msg.value, creatorFirstCommissionPercentage + creators[creator].royaltyPercentage));
        // 販売者への還元
        _asyncTransfer(seller, getShare(msg.value, sellerCommissionPercentage));
        withdrawPayments(payable(owner()));
        withdrawPayments(creator);
        withdrawPayments(seller);

        idToMarketItem[itemId].owner = payable(msg.sender);
        idToMarketItem[itemId].sold = true;
        idToMarketItem[itemId].seller = payable(address(0));
        _itemsSold.increment();

        // 販売者が製作者の場合にカウントとロイヤリティを追加する
        if (seller == creator) {
          creators[creator].salesCount += 1;
          if (creators[creator].royaltyPercentage < maxRoyaltyPercentage - creatorFirstCommissionPercentage) {
              creators[creator].royaltyPercentage += 10;
          }
         // イベントの発火
          emit RoyaltyIncreased (
            creator,
            creators[creator].salesCount,
            creators[creator].royaltyPercentage
          );
        }

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
        //distrubute dao token to buyer
        // DAOToken(daoToken).mint(msg.sender, buyNFTReward);

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

          emit BidCreated (
            bids[itemId]
          );

          // 入札最大金額より多くの金額を設定した場合、即時購入を実施
          if(reserved != 0 && msg.value >= reserved){
            // 金額の分配を実施
            // マーケットプレイスの手数料
            _asyncTransfer(owner(), getShare(reserved, ownerFirstCommissionPercentage - creators[creator].royaltyPercentage));
            // クリエイター報酬
            _asyncTransfer(creator, getShare(reserved, creatorFirstCommissionPercentage + creators[creator].royaltyPercentage));
            // 販売者への還元
            _asyncTransfer(seller, getShare(reserved, sellerCommissionPercentage));
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
            // bids[itemId] = Bid(block.timestamp, msg.sender, reserved);

            // 販売者が製作者の場合にカウントとロイヤリティを追加する
            if (seller == creator) {
              creators[creator].salesCount += 1;
              if (creators[creator].royaltyPercentage < maxRoyaltyPercentage - creatorFirstCommissionPercentage) {
                  creators[creator].royaltyPercentage += 10;
              }

              // イベントの発火
              emit RoyaltyIncreased (
                creator,
                creators[creator].salesCount,
                creators[creator].royaltyPercentage
              );
            }
            // NFT の所有権を売り手から買い手に譲渡します。
            IERC721(nftContract).transferFrom(address(this), msg.sender, tokenId);
          }
        // オークション終了の場合sellerが取引を締結するように設計
        }else{
          if(bids[itemId].value != 0){
            // ここは販売者じゃなくても大丈夫かも
            require(msg.sender == seller, "Can only be operated by sellers");
            // 金額の分配を実施
            // マーケットプレイスの手数料
            _asyncTransfer(owner(), getShare(bids[itemId].value, ownerFirstCommissionPercentage - creators[creator].royaltyPercentage));
            // クリエイター報酬
            _asyncTransfer(creator, getShare(bids[itemId].value, creatorFirstCommissionPercentage + creators[creator].royaltyPercentage));
            // 販売者への還元
            _asyncTransfer(seller, getShare(bids[itemId].value, sellerCommissionPercentage));
            withdrawPayments(payable(owner()));
            withdrawPayments(creator);
            withdrawPayments(seller);

            idToMarketItem[itemId].owner = payable(bids[itemId].bidder);
            idToMarketItem[itemId].sold = true;
            idToMarketItem[itemId].seller = payable(address(0));
            _itemsSold.increment();

            // 販売者が製作者の場合にカウントとロイヤリティを追加する
            if (seller == creator) {
              creators[creator].salesCount += 1;
              if (creators[creator].royaltyPercentage < maxRoyaltyPercentage - creatorFirstCommissionPercentage) {
                  creators[creator].royaltyPercentage += 10;
              }
              // イベントの発火
              emit RoyaltyIncreased (
                creator,
                creators[creator].salesCount,
                creators[creator].royaltyPercentage
              );
            }

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

      // 空のアドレスがある場合は、作成されたアイテムの数をループし、その数をインクリメントします
      // items という名前の空の配列
      // 配列内の要素の型は marketitem で、売れ残りの itemcount は length です
      MarketItem[] memory items = new MarketItem[](unsoldItemCount);
      for (uint i = 0; i < itemCount; i++) {
        // アイテムが売れ残っているかどうかを確認します -> 所有者が空のアドレスであるかどうかを確認します -> 売れ残りです
        // 上記では、新しいマーケットアイテムを作成していましたが、アドレスを空のアドレスに設定していました
        // アイテムが販売されている場合、アドレスが入力されます
        // tokenIdのスタートは1からなのでi+1を実行
        if (idToMarketItem[i + 1].owner == address(this) && idToMarketItem[i + 1].nftContract != address(0)) {
          // 現在やり取りしているアイテムのID
          uint currentId = idToMarketItem[i + 1].itemId;
          // idtomarketitemのマッピングを取得すると->marketitemへの参照が得られます
          MarketItem storage currentItem = idToMarketItem[currentId];
          // アイテム配列にマーケットアイテムを挿入します
          items[currentIndex] = currentItem;
          // 現在のインデックスを1増やす
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

      // 私たちが所有するアイテムの数を教えてくれます(gives us the number of items that we own)
      for (uint256 i = 0; i < totalItemCount; i++) {
        // nftが私のものかどうかを確認(check if nft is mine)
        if (idToMarketItem[i + 1].owner == msg.sender) {
          itemCount += 1;
        }
      }

      MarketItem[] memory items = new MarketItem[](itemCount);
      for (uint256 i = 0; i < totalItemCount; i++) {
        // nftが私のものかどうかを確認(check if nft is mine)
        if (idToMarketItem[i + 1].owner == msg.sender) {
          // マーケットアイテムのIDを取得する
          uint256 currentId = idToMarketItem[i + 1].itemId;
          // 現在のマーケット アイテムへの参照を取得する
          MarketItem storage currentItem = idToMarketItem[currentId];
          // 配列に挿入する
          items[currentIndex] = currentItem;
          // インデックスを1増やす
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

    /* クリエイターアドレスからNFT作品を取得*/
    function fetchItemsByAdd(address add, uint256 index) public view returns (MarketItem[] memory) {
      // index:1はseller情報の取得
      // それ以外はcreator情報の取得
      uint totalItemCount = _itemIds.current();
      uint itemCount = 0;
      uint currentIndex = 0;
      if(index == 1) {
        for (uint i = 0; i < totalItemCount; i++) {
          if (idToMarketItem[i + 1].seller == add) {
            itemCount += 1;
          }
        }
      } else {
        for (uint i = 0; i < totalItemCount; i++) {
          if (idToMarketItem[i + 1].creator == add) {
            itemCount += 1;
          }
        }
      }
      MarketItem[] memory items = new MarketItem[](itemCount);
      
      if(index == 1) {
        for (uint i = 0; i < totalItemCount; i++) {
          if (idToMarketItem[i + 1].seller == add) {
            uint currentId = idToMarketItem[i + 1].itemId;
            MarketItem storage currentItem = idToMarketItem[currentId];
            items[currentIndex] = currentItem;
            currentIndex += 1;
          }
        }
      } else {
        for (uint i = 0; i < totalItemCount; i++) {
          if (idToMarketItem[i + 1].creator == add) {
            uint currentId = idToMarketItem[i + 1].itemId;
            MarketItem storage currentItem = idToMarketItem[currentId];
            items[currentIndex] = currentItem;
            currentIndex += 1;
          }
        }
      }
      return items;
    }


}