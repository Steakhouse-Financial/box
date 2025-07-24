forge verify-contract \
  --chain-id 8453 \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  0x8eF325c3bDB2204A64B840E215aEebE8dA1A2Fb0 \
  lib/vault-v2/src/VaultV2.sol:VaultV2 \
  --compiler-version 0.8.28 \
  --constructor-args $(cast abi-encode "constructor(address,address,bytes32)" 0xfeed8591997D831f89BAF1089090918E669796C9 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 0x0000000000000000000000000000000000000000000000000000000000000000 )
