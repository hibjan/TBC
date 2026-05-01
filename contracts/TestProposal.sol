// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "./IExecutableProposal.sol";

contract TestProposal is IExecutableProposal, ERC165 {

    event Executed(uint proposalId, uint numVotes, uint numTokens, uint balance);

    function executeProposal(uint proposalId, uint numVotes, uint numTokens) external payable override {
        emit Executed(proposalId, numVotes, numTokens, address(this).balance);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165) returns (bool) {
        return interfaceId == type(IExecutableProposal).interfaceId ||
               super.supportsInterface(interfaceId);
    }
}
