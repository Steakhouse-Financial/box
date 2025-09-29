
source .env

FCT=$1

FOUNDRY_PROFILE=deploy

forge script script/DeployEthereum.s.sol:DeployEthereumScript  --sig "${FCT}()" \
  --rpc-url $ETH_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --chain-id 1
