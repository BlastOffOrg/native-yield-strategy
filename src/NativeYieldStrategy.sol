// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import "./BaseStrategy.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";

enum RebaseYieldMode {
    AUTOMATIC,
    VOID,
    CLAIMABLE
}

interface IERC20Rebasing is IERC20 {
    // changes the yield mode of the caller and update the balance
    // to reflect the configuration
    function configure(RebaseYieldMode) external returns (uint256);

    // "claimable" yield mode accounts can call this this claim their yield
    // to another address
    function claim(
        address recipient,
        uint256 amount
    ) external returns (uint256);

    // read the claimable amount for an account
    function getClaimableAmount(
        address account
    ) external view returns (uint256);
}

contract NativeYieldStrategy is BaseStrategy {
    constructor(address weth) BaseStrategy(weth, "Native ETH Yield") {
        IERC20Rebasing(weth).configure(RebaseYieldMode.AUTOMATIC);
    }

    function _deployFunds(uint256 _amount) internal virtual override {}

    function _freeFunds(uint256 _amount) internal virtual override {}

    function _harvestAndReport()
        internal
        virtual
        override
        returns (uint256 _totalAssets)
    {
        return IERC20(asset).balanceOf(address(this));
    }
}
