// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MuriFaucet — simple testnet token faucet
/// @notice Dispenses a fixed amount of native tokens per address with a cooldown period.
///         Owner can adjust parameters and withdraw funds.
contract MuriFaucet {
    address public owner;
    uint256 public claimAmount;
    uint256 public cooldown;

    mapping(address => uint256) public lastClaim;

    event Claimed(address indexed recipient, uint256 amount);
    event ClaimAmountUpdated(uint256 newAmount);
    event CooldownUpdated(uint256 newCooldown);
    event Withdrawn(address indexed to, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(uint256 _claimAmount, uint256 _cooldown) {
        owner = msg.sender;
        claimAmount = _claimAmount;
        cooldown = _cooldown;
    }

    receive() external payable {}

    function claim() external {
        require(
            block.timestamp >= lastClaim[msg.sender] + cooldown,
            "cooldown active"
        );
        require(address(this).balance >= claimAmount, "faucet empty");

        lastClaim[msg.sender] = block.timestamp;

        (bool ok, ) = msg.sender.call{value: claimAmount}("");
        require(ok, "transfer failed");

        emit Claimed(msg.sender, claimAmount);
    }

    function canClaim(address account) external view returns (bool) {
        return block.timestamp >= lastClaim[account] + cooldown;
    }

    function setClaimAmount(uint256 _claimAmount) external onlyOwner {
        claimAmount = _claimAmount;
        emit ClaimAmountUpdated(_claimAmount);
    }

    function setCooldown(uint256 _cooldown) external onlyOwner {
        cooldown = _cooldown;
        emit CooldownUpdated(_cooldown);
    }

    function withdraw(address to, uint256 amount) external onlyOwner {
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "transfer failed");
        emit Withdrawn(to, amount);
    }
}
