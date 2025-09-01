source .env

FCT=$1

forge script script/DeployBase.s.sol:DeployBaseScript  --sig "${FCT}()" \
  --rpc-url $BASE_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --chain-id 8453
