source .env

FCT=$1

FOUNDRY_PROFILE=deploy

forge script script/DeployBase.s.sol:DeployBaseScript  --sig "${FCT}()" \
  --rpc-url base \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --chain-id 8453
