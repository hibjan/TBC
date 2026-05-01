// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract VotingToken is ERC20 {

    address public owner; //QuadraticVoting

    uint public maxSupply;

    modifier onlyOwner() {
        require(msg.sender == owner, "VotingToken: solo el owner");
        _;
    }

    constructor(uint _maxSupply) ERC20("VotingToken", "VTK") {
        owner = msg.sender;
        maxSupply = _maxSupply;
    }

    function mint(address to, uint amount) external onlyOwner {
        require(totalSupply() + amount <= maxSupply, "VotingToken: cap excedido");
        _mint(to, amount);
    }

    function burn(address from, uint amount) external onlyOwner {
        _burn(from, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 0;
    }
}
