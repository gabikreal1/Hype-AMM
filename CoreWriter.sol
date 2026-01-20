// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


// only for testing purposes
// exposes a function to send raw actions to HyperCore
// Used only for lending/borrowing.
contract CoreWriter {
  event RawAction(address indexed user, bytes data);

  function sendRawAction(bytes calldata data) external {
    // Spends ~20k gas
    for (uint256 i = 0; i < 400; i++) {}
    emit RawAction(msg.sender, data);
  }
}
