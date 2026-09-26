RPC_URL ?= http://127.0.0.1:8545
FOUNDRY := PATH="$(HOME)/.foundry/bin:$$PATH"

.PHONY: build test coverage fmt demo demo-capital deploy-local

build:
	$(FOUNDRY) forge build

test:
	$(FOUNDRY) forge test -vv

coverage:
	$(FOUNDRY) forge coverage --report summary

fmt:
	$(FOUNDRY) forge fmt

## End-to-end scenario (no node required, simulation + logging)
demo:
	$(FOUNDRY) forge script script/DemoScenario.s.sol

## Wave 0 capital lifecycle (open→mint→swap→repay→close), no node required
demo-capital:
	$(FOUNDRY) forge script script/CapitalLifecycle.s.sol -vv

## Deploy to running anvil + write addresses/<profile>.json
deploy-local:
	$(FOUNDRY) RYEX_PROFILE=local-mock forge script script/Deploy.s.sol --broadcast --rpc-url $(RPC_URL)
