// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

contract NFT is ERC721URIStorage {
    using Counters for Counters.Counter;    

    Counters.Counter private _tokenIds;

    struct PartnerRoyalty {
        address wallet;
        uint fee;
    }

    mapping(uint256 => PartnerRoyalty) private partnerRoyaltyRegister;

    constructor() ERC721("GiveTree NFT", "GNFT") {}

    function mintToken(string memory tokenURI, address partner, uint fee)
        public
        returns (uint256)
    {
        _tokenIds.increment();

        uint256 newItemId = _tokenIds.current();
        _mint(msg.sender, newItemId);
        _setTokenURI(newItemId, tokenURI);
        partnerRoyaltyRegister[newItemId] = PartnerRoyalty({
            wallet: partner, 
            fee: fee
        });

        return newItemId;
    }

    function partnerRoyaltyOf(uint tokenId) 
        external view 
        returns (address, uint) 
    {
        require(_exists(tokenId), "GiveTree: royalty query for nonexistent token");

        return (partnerRoyaltyRegister[tokenId].wallet, partnerRoyaltyRegister[tokenId].fee);
    }
}