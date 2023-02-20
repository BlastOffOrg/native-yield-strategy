// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.8.14;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {DiamondHelper, IDiamond, IDiamondLoupe} from "../DiamondHelper.sol";

import {IBaseStrategy} from "../interfaces/IBaseStrategy.sol";

interface IBaseFee {
    function isCurrentBaseFeeAcceptable() external view returns (bool);
}

import "forge-std/console.sol";

/// TODO:
//      Add api version
//      Add health check
//      add events
//      add emergency exit? and emergency admin?
//      forceReportTrigger?

library BaseLibrary {
    using SafeERC20 for ERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );

    event Deposit(
        address indexed caller,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    event Withdraw(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    event Reported(uint256 profit, uint256 loss, uint256 fees);

    event DiamondCut(
        IDiamond.FacetCut[] _diamondCut,
        address _init,
        bytes _calldata
    );

    /*//////////////////////////////////////////////////////////////
                                Errors
    //////////////////////////////////////////////////////////////*/

    error Unauthorized();

    /*//////////////////////////////////////////////////////////////
                        STORAGE STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct ERC20Data {
        ERC20 asset;
        mapping(address => uint256) balances;
        mapping(address => mapping(address => uint256)) allowances;
        uint256 totalSupply;
        uint8 decimals;
    }

    struct AssetsData {
        uint256 totalIdle;
        uint256 totalDebt;
    }

    struct ProfitData {
        uint256 fullProfitUnlockDate;
        uint256 profitUnlockingRate;
        uint256 profitMaxUnlockTime;
        uint256 lastReport;
        uint256 performanceFee;
        address treasury;
    }

    struct AccessData {
        address management;
        address keeper;
    }

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyManagement() {
        _onlyManagement();
        _;
    }

    modifier onlyKeepers() {
        _onlyKeepers();
        _;
    }

    function _onlyManagement() public view {
        if (msg.sender != _accessStorage().management) revert Unauthorized();
    }

    function _onlyKeepers() public view {
        AccessData storage c = _accessStorage();
        if (msg.sender != c.management && msg.sender != c.keeper)
            revert Unauthorized();
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANT
    //////////////////////////////////////////////////////////////*/

    // NOTE: holder address based on expected location during tests
    address public constant diamondHelper =
        0xFEfC6BAF87cF3684058D62Da40Ff3A795946Ab06;

    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant MAX_BPS_EXTENDED = 1_000_000_000_000;

    // storage slot to use for ERC20 variables
    bytes32 internal constant ERC20_STRATEGY_STORAGE =
        bytes32(uint256(keccak256("yearn.erc20.strategy.storage")) - 1);

    bytes32 internal constant ASSETS_STRATEGY_STORAGE =
        bytes32(uint256(keccak256("yearn.assets.strategy.storage")) - 1);

    // storage slot to use for report/ profit locking variables
    bytes32 internal constant PROFIT_LOCKING_STORAGE =
        bytes32(uint256(keccak256("yearn.profit.locking.storage")) - 1);

    // storage slot to use for the permissined addresses for a strategy
    bytes32 internal constant ACCESS_CONTROL_STORAGE =
        bytes32(uint256(keccak256("yearn.access.control.storage")) - 1);

    /*//////////////////////////////////////////////////////////////
                    STORAGE GETTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _erc20Storage() private pure returns (ERC20Data storage e) {
        // Since STORAGE_SLOT is a constant, we have to put a variable
        // on the stack to access it from an inline assembly block.
        bytes32 slot = ERC20_STRATEGY_STORAGE;
        assembly {
            e.slot := slot
        }
    }

    function _assetsStorage() private pure returns (AssetsData storage a) {
        // Since STORAGE_SLOT is a constant, we have to put a variable
        // on the stack to access it from an inline assembly block.
        bytes32 slot = ASSETS_STRATEGY_STORAGE;
        assembly {
            a.slot := slot
        }
    }

    function _profitStorage() private pure returns (ProfitData storage p) {
        // Since STORAGE_SLOT is a constant, we have to put a variable
        // on the stack to access it from an inline assembly block.
        bytes32 slot = PROFIT_LOCKING_STORAGE;
        assembly {
            p.slot := slot
        }
    }

    function _accessStorage() private pure returns (AccessData storage c) {
        // Since STORAGE_SLOT is a constant, we have to put a variable
        // on the stack to access it from an inline assembly block.
        bytes32 slot = ACCESS_CONTROL_STORAGE;
        assembly {
            c.slot := slot
        }
    }

    /*//////////////////////////////////////////////////////////////
                INITILIZATION OF DEFAULT STORAGE
    //////////////////////////////////////////////////////////////*/

    function init(address _asset, address _management) external {
        // cache storage pointer
        ERC20Data storage e = _erc20Storage();

        // make sure we aren't initiliazed
        require(address(e.asset) == address(0), "!init");
        // set the strategys underlying asset
        e.asset = ERC20(_asset);

        // set the default management address
        _accessStorage().management = _management;

        // cache profit data pointer
        ProfitData storage p = _profitStorage();
        // default to a 10 day profit unlock period
        p.profitMaxUnlockTime = 10 days;
        // default to mangement as the treasury TODO: allow this to be customized
        p.treasury = _management;
        // default to a 10% performance fee
        p.performanceFee = 1_000;
        // set last report to this block
        p.lastReport = block.timestamp;

        // emit the standard DiamondCut event with the values from out helper contract
        emit DiamondCut(
            // struct containing the address of the library, the add enum and array of all function selectors
            DiamondHelper(diamondHelper).diamondCut(),
            // init address to call if applicable
            address(0),
            // call data to send the init address if applicable
            new bytes(0)
        );
    }

    /*//////////////////////////////////////////////////////////////
                        ERC4626 FUNCIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 assets, address receiver)
        public
        returns (uint256 shares)
    {
        // check lower than max
        require(
            assets <= IBaseStrategy(address(this)).maxDeposit(receiver),
            "ERC4626: deposit more than max"
        );

        // Check for rounding error since we round down in previewDeposit.
        require((shares = previewDeposit(assets)) != 0, "ZERO_SHARES");

        // Need to transfer before minting or ERC777s could reenter.
        _erc20Storage().asset.safeTransferFrom(
            msg.sender,
            address(this),
            assets
        );

        // mint shares
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        // let strategy invest the funds if applicable
        _depositFunds(assets);
    }

    function mint(uint256 shares, address receiver)
        public
        returns (uint256 assets)
    {
        require(
            shares <= IBaseStrategy(address(this)).maxMint(receiver),
            "ERC4626: mint more than max"
        );

        assets = previewMint(shares); // No need to check for rounding error, previewMint rounds up.

        // Need to transfer before minting or ERC777s could reenter.
        _erc20Storage().asset.safeTransferFrom(
            msg.sender,
            address(this),
            assets
        );

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        // let strategy invest the funds if applicable
        _depositFunds(assets);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public returns (uint256 shares) {
        require(
            assets <= IBaseStrategy(address(this)).maxWithdraw(owner),
            "ERC4626: withdraw more than max"
        );

        shares = previewWithdraw(assets); // No need to check for rounding error, previewWithdraw rounds up.

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        _freeFunds(assets);

        _burn(owner, shares);

        _erc20Storage().asset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public returns (uint256 assets) {
        require(
            shares <= IBaseStrategy(address(this)).maxRedeem(owner),
            "ERC4626: redeem more than max"
        );

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // Check for rounding error since we round down in previewRedeem.
        require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        // withdraw if we dont have enough idle
        _freeFunds(assets);

        _burn(owner, shares);

        _erc20Storage().asset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    // post deposit/report hook to deposit any loose funds
    function _depositFunds(uint256 _newAmount) internal {
        AssetsData storage a = _assetsStorage();

        // invest if applicable
        uint256 toInvest = a.totalIdle + _newAmount;
        uint256 invested = IBaseStrategy(address(this)).invest(toInvest);

        // adjust total Assets
        // TODO: should there be a min check here in case donated asset was accounted for?
        a.totalDebt += invested;
        // check if we invested all the loose asset
        a.totalIdle = invested >= toInvest ? 0 : toInvest - invested;
    }

    function _freeFunds(uint256 _amount) internal {
        AssetsData storage a = _assetsStorage();

        // withdraw if we dont have enough idle
        uint256 idle = a.totalIdle;

        if (idle >= _amount) {
            a.totalIdle -= _amount;
        } else {
            // free what we need -  what we have
            // TODO: should account for errors here and not overflow
            a.totalDebt -= IBaseStrategy(address(this)).freeFunds(
                _amount - idle
            );
            // we are giving the full amount of our idle funds
            a.totalIdle = 0;
        }
    }

    /*//////////////////////////////////////////////////////////////
                        PROFIT LOCKING
    //////////////////////////////////////////////////////////////*/

    function report()
        public
        onlyKeepers
        returns (uint256 profit, uint256 loss)
    {
        // burn unlocked shares
        _burnUnlockedShares();

        // tell the strategy to report the real total assets it has
        uint256 _invested = IBaseStrategy(address(this)).totalInvested();

        AssetsData storage a = _assetsStorage();

        // calculate profit
        uint256 debt = a.totalDebt;

        if (_invested >= debt) {
            profit = _invested - debt;
            debt += profit;
        } else {
            loss = debt - _invested;
            debt -= loss;
        }

        // TODO: healthcheck ?

        ProfitData storage p = _profitStorage();
        uint256 fees;
        uint256 sharesToLock;
        // only assess fees and lock shares if we have a profit
        if (profit > 0) {
            // asses fees
            fees = (profit * p.performanceFee) / MAX_BPS;

            // issue all new shares to self
            sharesToLock = convertToShares(profit - fees);
            uint256 feeShares = convertToShares(fees);

            // send shares to treasury
            _mint(p.treasury, feeShares);

            // mint the rest of profit to self for locking
            _mint(address(this), sharesToLock);
        }

        // TODO: Should this account for losses like vault does

        // lock (profit - fees) of shares issued
        uint256 remainingTime;
        uint256 _fullProfitUnlockDate = p.fullProfitUnlockDate;
        if (_fullProfitUnlockDate > block.timestamp) {
            remainingTime = _fullProfitUnlockDate - block.timestamp;
        }

        // Update unlocking rate and time to fully unlocked
        uint256 totalLockedShares = balanceOf(address(this));
        uint256 _profitMaxUnlockTime = p.profitMaxUnlockTime;
        if (totalLockedShares > 0 && _profitMaxUnlockTime > 0) {
            uint256 previouslyLockedShares = totalLockedShares - sharesToLock;

            // new_profit_locking_period is a weighted average between the remaining time of the previously locked shares and the PROFIT_MAX_UNLOCK_TIME
            uint256 newProfitLockingPeriod = (previouslyLockedShares *
                remainingTime +
                sharesToLock *
                _profitMaxUnlockTime) / totalLockedShares;

            p.profitUnlockingRate =
                (totalLockedShares * MAX_BPS_EXTENDED) /
                newProfitLockingPeriod;

            p.fullProfitUnlockDate = block.timestamp + newProfitLockingPeriod;
        } else {
            // NOTE: only setting this to 0 will turn in the desired effect, no need to update last_profit_update or fullProfitUnlockDate
            p.profitUnlockingRate = 0;
        }

        // update storage variables
        a.totalDebt = debt;
        p.lastReport = block.timestamp;

        // emit event with info
        emit Reported(profit, loss, fees);

        // invest any idle funds
        _depositFunds(0);
    }

    function _burnUnlockedShares() internal {
        uint256 unlcokdedShares = _unlockedShares();
        if (unlcokdedShares == 0) {
            return;
        }

        // update variables (done here to keep _unlcokdedShares() as a view function)
        if (_profitStorage().fullProfitUnlockDate > block.timestamp) {
            _profitStorage().lastReport = block.timestamp;
        }

        _burn(address(this), unlcokdedShares);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view returns (uint256) {
        AssetsData storage a = _assetsStorage();
        return a.totalIdle + a.totalDebt;
    }

    function totalSupply() public view returns (uint256) {
        return _erc20Storage().totalSupply - _unlockedShares();
    }

    function _unlockedShares() internal view returns (uint256) {
        // should save 2 extra calls for most of the time
        ProfitData storage p = _profitStorage();
        uint256 _fullProfitUnlockDate = p.fullProfitUnlockDate;
        uint256 unlockedShares;
        if (_fullProfitUnlockDate > block.timestamp) {
            unlockedShares =
                (p.profitUnlockingRate * (block.timestamp - p.lastReport)) /
                MAX_BPS_EXTENDED;
        } else if (_fullProfitUnlockDate != 0) {
            // All shares have been unlocked
            unlockedShares = balanceOf(address(this));
        }

        return unlockedShares;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply(); // Saves an extra SLOAD if totalSupply() is non-zero.

        return
            supply == 0
                ? assets
                : assets.mulDiv(supply, totalAssets(), Math.Rounding.Down);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply(); // Saves an extra SLOAD if totalSupply() is non-zero.

        return
            supply == 0
                ? shares
                : shares.mulDiv(totalAssets(), supply, Math.Rounding.Down);
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply(); // Saves an extra SLOAD if totalSupply() is non-zero.

        return
            supply == 0
                ? shares
                : shares.mulDiv(totalAssets(), supply, Math.Rounding.Up);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply(); // Saves an extra SLOAD if totalSupply() is non-zero.

        return
            supply == 0
                ? assets
                : assets.mulDiv(supply, totalAssets(), Math.Rounding.Up);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    /*//////////////////////////////////////////////////////////////
                        Getter FUNCIONS
    //////////////////////////////////////////////////////////////*/

    // External view function to pull public variables from storage

    function pricePerShare() external view returns (uint256) {
        return convertToAssets(10**IBaseStrategy(address(this)).decimals());
    }

    function totalIdle() external view returns (uint256) {
        return _assetsStorage().totalIdle;
    }

    function totalDebt() external view returns (uint256) {
        return _assetsStorage().totalDebt;
    }

    function management() external view returns (address) {
        return _accessStorage().management;
    }

    function keeper() external view returns (address) {
        return _accessStorage().keeper;
    }

    function performanceFee() external view returns (uint256) {
        return _profitStorage().performanceFee;
    }

    function treasury() external view returns (address) {
        return _profitStorage().treasury;
    }

    function profitMaxUnlockTime() external view returns (uint256) {
        return _profitStorage().profitMaxUnlockTime;
    }

    /*//////////////////////////////////////////////////////////////
                        SETTER FUNCIONS
    //////////////////////////////////////////////////////////////*/

    // TODO: These should all emit events

    function setManagement(address _management) external onlyManagement {
        require(_management != address(0), "ZERO ADDRESS");
        _accessStorage().management = _management;
    }

    function setKeeper(address _keeper) external onlyManagement {
        _accessStorage().keeper = _keeper;
    }

    function setPerformanceFee(uint256 _performanceFee)
        external
        onlyManagement
    {
        require(_performanceFee < MAX_BPS, "MAX BPS");
        _profitStorage().performanceFee = _performanceFee;
    }

    function setTreasury(address _treasury) external onlyManagement {
        require(_treasury != address(0), "ZERO ADDRESS");
        _profitStorage().treasury = _treasury;
    }

    function setProfitMaxUnlockTime(uint256 _profitMaxUnlockTime)
        external
        onlyManagement
    {
        _profitStorage().profitMaxUnlockTime = _profitMaxUnlockTime;
    }

    /*//////////////////////////////////////////////////////////////
                    REPORT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function reportTrigger() external view returns (bool) {
        // nothing to report
        if (_assetsStorage().totalDebt == 0) return false;

        // to costly
        if (!isBaseFeeAcceptable()) return false;

        return
            block.timestamp - _profitStorage().lastReport >
            _profitStorage().profitMaxUnlockTime;
    }

    function tendTrigger() external pure returns (bool) {
        return false;
    }

    function isBaseFeeAcceptable() public view returns (bool) {
        return
            IBaseFee(0xb5e1CAcB567d98faaDB60a1fD4820720141f064F)
                .isCurrentBaseFeeAcceptable();
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL EIP-2535 VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // TODO: Implement the Diamon Loupe function using the selector helper
    /// @notice Gets all facet addresses and their four byte function selectors.
    /// @return facets_ Facet
    function facets() external view returns (IDiamondLoupe.Facet[] memory) {
        return DiamondHelper(diamondHelper).facets();
    }

    /// @notice Gets all the function selectors supported by a specific facet.
    /// @param _facet The facet address.
    /// @return facetFunctionSelectors_
    function facetFunctionSelectors(address _facet)
        external
        view
        returns (bytes4[] memory)
    {
        return DiamondHelper(diamondHelper).facetFunctionSelectors(_facet);
    }

    /// @notice Get all the facet addresses used by a diamond.
    /// @return facetAddresses_
    function facetAddresses() external view returns (address[] memory) {
        return DiamondHelper(diamondHelper).facetAddresses();
    }

    /// @notice Gets the facet that supports the given selector.
    /// @dev If facet is not found return address(0).
    /// @param _functionSelector The function selector.
    /// @return facetAddress_ The facet address.
    function facetAddress(bytes4 _functionSelector)
        external
        view
        returns (address)
    {
        return DiamondHelper(diamondHelper).facetAddress(_functionSelector);
    }

    /*//////////////////////////////////////////////////////////////
                        ERC20 FUNCIONS
    //////////////////////////////////////////////////////////////*/

    // TODO: ADD permit functions

    function balanceOf(address account) public view returns (uint256) {
        return _erc20Storage().balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(address to, uint256 amount) public returns (bool) {
        address owner = msg.sender;
        _transfer(owner, to, amount);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender)
        public
        view
        returns (uint256)
    {
        return _erc20Storage().allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * NOTE: If `amount` is the maximum `uint256`, the allowance is not updated on
     * `transferFrom`. This is semantically equivalent to an infinite approval.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 amount) public returns (bool) {
        address owner = msg.sender;
        _approve(owner, spender, amount);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20}.
     *
     * NOTE: Does not update the allowance if the current allowance
     * is the maximum `uint256`.
     *
     * Requirements:
     *
     * - `from` and `to` cannot be the zero address.
     * - `from` must have a balance of at least `amount`.
     * - the caller must have allowance for ``from``'s tokens of at least
     * `amount`.
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public returns (bool) {
        address spender = msg.sender;
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
        return true;
    }

    /**
     * @dev Atomically increases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function increaseAllowance(address spender, uint256 addedValue)
        public
        returns (bool)
    {
        address owner = msg.sender;
        _approve(owner, spender, allowance(owner, spender) + addedValue);
        return true;
    }

    /**
     * @dev Atomically decreases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `spender` must have allowance for the caller of at least
     * `subtractedValue`.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue)
        public
        returns (bool)
    {
        address owner = msg.sender;
        uint256 currentAllowance = allowance(owner, spender);
        require(
            currentAllowance >= subtractedValue,
            "ERC20: decreased allowance below zero"
        );
        unchecked {
            _approve(owner, spender, currentAllowance - subtractedValue);
        }

        return true;
    }

    /**
     * @dev Moves `amount` of tokens from `from` to `to`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `from` must have a balance of at least `amount`.
     */
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        uint256 fromBalance = _erc20Storage().balances[from];
        require(
            fromBalance >= amount,
            "ERC20: transfer amount exceeds balance"
        );
        unchecked {
            _erc20Storage().balances[from] = fromBalance - amount;
        }
        _erc20Storage().balances[to] += amount;

        emit Transfer(from, to, amount);
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: mint to the zero address");

        _erc20Storage().totalSupply += amount;
        _erc20Storage().balances[account] += amount;
        emit Transfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: burn from the zero address");

        uint256 accountBalance = _erc20Storage().balances[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        unchecked {
            _erc20Storage().balances[account] = accountBalance - amount;
        }
        _erc20Storage().totalSupply -= amount;

        emit Transfer(account, address(0), amount);
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _erc20Storage().allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @dev Updates `owner` s allowance for `spender` based on spent `amount`.
     *
     * Does not update the allowance amount in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Might emit an {Approval} event.
     */
    function _spendAllowance(
        address owner,
        address spender,
        uint256 amount
    ) internal {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(
                currentAllowance >= amount,
                "ERC20: insufficient allowance"
            );
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }
}