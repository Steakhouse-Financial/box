// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Steakhouse Financial
pragma solidity ^0.8.28;

import {FundingMorpho} from "../FundingMorpho.sol";

contract FundingMorphoFactory {
    /* STORAGE */

    mapping(address account => bool) public isFundingMorpho;

    /* EVENTS */
    event CreateFundingMorpho(address indexed owner, address indexed morpho, FundingMorpho fundingMorpho);

    /* FUNCTIONS */

    function createFundingMorpho(address owner_, address morpho_) external returns (FundingMorpho) {
        FundingMorpho _funding = new FundingMorpho(
            owner_,
            morpho_
        );

        isFundingMorpho[address(_funding)] = true;

        emit CreateFundingMorpho(owner_, morpho_, _funding);

        return _funding;
    }
}
