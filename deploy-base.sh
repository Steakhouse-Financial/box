forge script script/Deploy.s.sol:DeployScript --sig "deployPeaty()" \
  --rpc-url $BASE_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --chain-id 8453
