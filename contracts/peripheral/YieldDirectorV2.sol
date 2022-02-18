// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.10;

import {IERC20} from "../interfaces/IERC20.sol";
import {IsOHM} from "../interfaces/IsOHM.sol";
import {IStaking} from "../interfaces/IStaking.sol";
import {SafeERC20} from "../libraries/SafeERC20.sol";
import {YieldSplitter} from "../types/YieldSplitter.sol";
import {OlympusAccessControlled, IOlympusAuthority} from "../types/OlympusAccessControlled.sol";

/**
    @title  YieldDirectorV2 (codename Tyche) 
    @notice This contract allows donors to deposit their gOHM and donate their rebases
            to any address. Donors will be able to withdraw the sOHM equivalent of their principal
            gOHM at any time. Donation recipients can also redeem accrued rebases at any time.
    @dev    Any functions dealing with initial deposits will take an address (because no ID has been
            assigned). After a user has deposited, all functions dealing with deposits (like
            withdraw or redeem functions) will take the ID of the deposit. All functions that return
            aggregated data grouped by user will take an address (iterates across all relevant IDs).
 */
contract YieldDirectorV2 is YieldSplitter, OlympusAccessControlled {
    using SafeERC20 for IERC20;

    error YieldDirector_InvalidAddress();
    error YieldDirector_InvalidDeposit();
    error YieldDirector_InvalidUpdate();
    error YieldDirector_InvalidWithdrawal();
    error YieldDirector_NotYourDeposit();
    error YieldDirector_NoDeposits();
    error YieldDirector_NoRedeemableBalance();
    error YieldDirector_WithdrawalsDisabled();
    error YieldDirector_RedeemsDisabled();

    address public immutable sOHM;
    address public immutable gOHM;
    IStaking public immutable staking;

    mapping(address => uint256[]) public recipientIds; // address -> array of deposit id's donating yield to the user
    mapping(uint256 => address) public recipientLookup; // depositId -> recipient

    bool public depositDisabled;
    bool public withdrawDisabled;
    bool public redeemDisabled;

    event Deposited(address indexed donor_, address indexed recipient_, uint256 amount_);
    event Withdrawn(address indexed donor_, address indexed recipient_, uint256 amount_);
    event AllWithdrawn(address indexed donor_, uint256 indexed amount_);
    event Donated(address indexed donor_, address indexed recipient_, uint256 amount_);
    event Redeemed(address indexed recipient_, uint256 amount_);
    event EmergencyShutdown(bool active_);

    constructor(
        address sOhm_,
        address gOhm_,
        address staking_,
        address authority_
    ) OlympusAccessControlled(IOlympusAuthority(authority_)) YieldSplitter(sOhm_) {
        if (sOhm_ == address(0) || gOhm_ == address(0) || staking_ == address(0) || authority_ == address(0))
            revert YieldDirector_InvalidAddress();

        sOHM = sOhm_;
        gOHM = gOhm_;
        staking = IStaking(staking_);
    }

    /************************
     * Modifiers
     ************************/
    function isInvalidDeposit(uint256 amount_, address recipient_) internal view returns (bool) {
        return depositDisabled || amount_ <= 0 || recipient_ == address(0);
    }

    function isInvalidUpdate(uint256 depositId_, uint256 amount_) internal view returns (bool) {
        return depositDisabled || amount_ <= 0 || depositInfo[depositId_].depositor == address(0);
    }

    function isInvalidWithdrawal(uint256 amount_) internal view returns (bool) {
        return withdrawDisabled || amount_ <= 0;
    }

    /************************
     * Donor Functions
     ************************/

    /**
        @notice Deposit gOHM, records sender address and assign rebases to recipient
        @param amount_ Amount of gOHM debt issued from donor to recipient
        @param recipient_ Address to direct staking yield and vault shares to
    */
    function deposit(uint256 amount_, address recipient_) external returns (uint256 depositId) {
        if (isInvalidDeposit(amount_, recipient_)) revert YieldDirector_InvalidDeposit();

        IERC20(gOHM).safeTransferFrom(msg.sender, address(this), amount_);

        depositId = _createDeposit(amount_, recipient_);
    }

    /**
        @notice Deposit sOHM, wrap to gOHM, and records sender address and assign rebases to recipeint
        @param amount_ Amount of sOHM debt issued from donor to recipient
        @param recipient_ Address to direct staking yield and vault shares to
    */
    function depositSohm(uint256 amount_, address recipient_) external returns (uint256 depositId) {
        if (isInvalidDeposit(amount_, recipient_)) revert YieldDirector_InvalidDeposit();

        IERC20(sOHM).safeTransferFrom(msg.sender, address(this), amount_);
        IERC20(sOHM).approve(address(staking), amount_);
        uint256 gohmAmount = staking.wrap(address(this), amount_);

        depositId = _createDeposit(gohmAmount, recipient_);
    }

    /**
        @notice Deposit additional gOHM, and update deposit record
        @param depositId_ Deposit ID to direct additional gOHM to
        @param amount_ Amount of new gOHM debt issued from donor to recipient
    */
    function addToDeposit(uint256 depositId_, uint256 amount_) external {
        if (isInvalidUpdate(depositId_, amount_)) revert YieldDirector_InvalidUpdate();
        if (depositInfo[depositId_].depositor != msg.sender) revert YieldDirector_NotYourDeposit();

        IERC20(gOHM).safeTransferFrom(msg.sender, address(this), amount_);

        _increaseDeposit(depositId_, amount_);
    }

    /**
        @notice Deposit additional sOHM, wrap to gOHM, and update deposit record
        @param depositId_ Deposit ID to direct additional gOHM to
        @param amount_ Amount of new sOHM debt issued from donor to recipient
    */
    function addToSohmDeposit(uint256 depositId_, uint256 amount_) external {
        if (isInvalidUpdate(depositId_, amount_)) revert YieldDirector_InvalidUpdate();
        if (depositInfo[depositId_].depositor != msg.sender) revert YieldDirector_NotYourDeposit();

        IERC20(sOHM).safeTransferFrom(msg.sender, address(this), amount_);
        IERC20(sOHM).approve(address(staking), amount_);
        uint256 gohmAmount = staking.wrap(address(this), amount_);

        _increaseDeposit(depositId_, gohmAmount);
    }

    /**
        @notice Withdraw donor's gOHM from vault
        @param depositId_ Deposit ID to remove gOHM deposit from
        @param amount_ Amount of gOHM deposit to remove and return to donor
    */
    function withdrawPrincipal(uint256 depositId_, uint256 amount_) external {
        uint256 amountWithdrawn = _withdraw(depositId_, amount_);

        IERC20(gOHM).safeTransfer(msg.sender, amountWithdrawn);
    }

    /**
        @notice Withdraw donor's gOHM from vault, and return it as sOHM
        @param depositId_ Deposit ID to remove gOHM debt from
        @param amount_ Amount of gOHM debt to remove and return to donor as sOHM
    */
    function withdrawPrincipalAsSohm(uint256 depositId_, uint256 amount_) external {
        uint256 amountWithdrawn = _withdraw(depositId_, amount_);

        IERC20(sOHM).approve(address(staking), amountWithdrawn);
        staking.unwrap(msg.sender, amountWithdrawn);
    }

    /**
        @notice Withdraw all gOHM from all donor positions
    */
    function withdrawAll() external {
        if (withdrawDisabled) revert YieldDirector_WithdrawalsDisabled();

        uint256[] memory depositIds = depositorIds[msg.sender];

        uint256 depositsLength = depositIds.length;
        if (depositsLength == 0) revert YieldDirector_NoDeposits();

        uint256 principalTotal = 0;

        for (uint256 index = 0; index < depositsLength; ++index) {
            DepositInfo storage currDeposit = depositInfo[depositIds[index]];

            principalTotal += currDeposit.principalAmount;

            _withdrawAllPrincipal(depositIds[index]);
        }

        IERC20(gOHM).safeTransfer(msg.sender, _toAgnostic(principalTotal));

        emit AllWithdrawn(msg.sender, _toAgnostic(principalTotal));
    }

    /**
        @notice Get deposited gOHM amounts for specific recipient (updated to current index
                based on sOHM equivalent amount deposit)
        @param donor_ Address of user donating yield
        @param recipient_ Address of user receiving donated yield
    */
    function depositsTo(address donor_, address recipient_) external view returns (uint256) {
        uint256[] storage depositIds = depositorIds[donor_];

        for (uint256 index = 0; index < depositIds.length; ++index) {
            uint256 id = depositIds[index];

            if (recipientLookup[id] == recipient_) {
                return _toAgnostic(depositInfo[id].principalAmount);
            }
        }

        return 0;
    }

    /**
        @notice Return total amount of donor's gOHM deposited (updated to current index based
                on sOHM equivalent amount deposited)
        @param donor_ Address of user donating yield
    */
    function totalDeposits(address donor_) external view returns (uint256) {
        uint256[] storage depositIds = depositorIds[donor_];
        uint256 principalTotal = 0;

        for (uint256 index = 0; index < depositIds.length; ++index) {
            principalTotal += depositInfo[depositIds[index]].principalAmount;
        }

        return _toAgnostic(principalTotal);
    }

    /**
        @notice Return arrays of donor's recipients and deposit amounts (gOHM value based on
                sOHM equivalent deposit), matched by index
        @param donor_ Address of user donating yield
    */
    function getAllDeposits(address donor_) external view returns (address[] memory, uint256[] memory) {
        uint256[] storage depositIds = depositorIds[donor_];

        uint256 len = depositIds.length == 0 ? 1 : depositIds.length;

        address[] memory addresses = new address[](len);
        uint256[] memory agnosticDeposits = new uint256[](len);

        if (depositIds.length == 0) {
            addresses[0] = address(0);
            agnosticDeposits[0] = 0;
        } else {
            for (uint256 index = 0; index < len; ++index) {
                addresses[index] = recipientLookup[depositIds[index]];
                agnosticDeposits[index] = _toAgnostic(depositInfo[depositIds[index]].principalAmount);
            }
        }

        return (addresses, agnosticDeposits);
    }

    /**
        @notice Return total amount of gOHM donated to recipient since last full redemption
        @param donor_ Address of user donating yield
        @param recipient_ Address of user recieiving donated yield
    */
    function donatedTo(address donor_, address recipient_) external view returns (uint256) {
        uint256[] storage depositIds = depositorIds[donor_];

        for (uint256 index = 0; index < depositIds.length; ++index) {
            if (recipientLookup[depositIds[index]] == recipient_) {
                return redeemableBalance(depositIds[index]);
            }
        }

        return 0;
    }

    /**
        @notice Return total amount of gOHM donated from donor since last full redemption
        @param donor_ Address of user donating yield
    */
    function totalDonated(address donor_) external view returns (uint256) {
        uint256[] storage depositIds = depositorIds[donor_];

        uint256 principalTotal = 0;
        uint256 agnosticTotal = 0;

        for (uint256 index = 0; index < depositIds.length; ++index) {
            DepositInfo storage currDeposit = depositInfo[depositIds[index]];

            principalTotal += currDeposit.principalAmount;
            agnosticTotal += currDeposit.agnosticAmount;
        }

        return _getOutstandingYield(principalTotal, agnosticTotal);
    }

    /************************
     * Recipient Functions
     ************************/

    /**
        @notice Get redeemable gOHM balance of a specific deposit
        @param depositId_ Deposit ID for this donation
    */
    function redeemableBalance(uint256 depositId_) public view returns (uint256) {
        DepositInfo storage currDeposit = depositInfo[depositId_];

        return _getOutstandingYield(currDeposit.principalAmount, currDeposit.agnosticAmount);
    }

    /**
        @notice Get redeemable gOHM balance of a recipient address
        @param recipient_ Address of user receiving donated yield
     */
    function totalRedeemableBalance(address recipient_) public view returns (uint256) {
        uint256[] storage receiptIds = recipientIds[recipient_];

        uint256 agnosticRedeemable = 0;

        for (uint256 index = 0; index < receiptIds.length; ++index) {
            agnosticRedeemable += redeemableBalance(receiptIds[index]);
        }

        return agnosticRedeemable;
    }

    /**
        @notice Redeem recipient's donated amount of sOHM at current index from one donor as gOHM
        @param depositId_ Deposit ID for this donation
    */
    function redeemYield(uint256 depositId_) external {
        uint256 amountRedeemed = _redeem(depositId_);

        IERC20(gOHM).safeTransfer(msg.sender, amountRedeemed);
    }

    /**
        @notice Redeem recipient's donated amount of sOHM at current index
        @param depositId_ Deposit id for this donation
    */
    function redeemYieldAsSohm(uint256 depositId_) external {
        uint256 amountRedeemed = _redeem(depositId_);

        IERC20(sOHM).approve(address(staking), amountRedeemed);
        staking.unwrap(msg.sender, amountRedeemed);
    }

    /**
        @notice Redeem recipient's full donated amount of sOHM at current index as gOHM
    */
    function redeemAllYield() external {
        uint256 amountRedeemed = _redeemAll();

        IERC20(gOHM).safeTransfer(msg.sender, amountRedeemed);
    }

    /**
        @notice Redeem recipient's full donated amount of sOHM at current index as gOHM
    */
    function redeemAllYieldAsSohm() external {
        uint256 amountRedeemed = _redeemAll();

        IERC20(sOHM).approve(address(staking), amountRedeemed);
        staking.unwrap(msg.sender, amountRedeemed);
    }

    /************************
     * Internal Functions
     ************************/

    /**
        @notice Creates a new deposit directing the yield from the deposited gOHM amount
                to the prescribed recipient
        @param amount_ Quantity of gOHM deposited redirecting yield to the recipient
        @param recipient_ The address of the user who will be entitled to claim the donated yield
    */
    function _createDeposit(uint256 amount_, address recipient_) internal returns (uint256 depositId) {
        depositId = _deposit(msg.sender, amount_);
        recipientIds[recipient_].push(depositId);
        recipientLookup[depositId] = recipient_;

        emit Deposited(msg.sender, recipient_, amount_);
    }

    /**
        @notice Increases the amount of gOHM directing yield to a recipient
        @param depositId_ The global ID number of the deposit to add the additional deposit to
        @param amount_ Quantity of new gOHM deposited redirecting yield to the current deposit's recipient
    */
    function _increaseDeposit(uint256 depositId_, uint256 amount_) internal {
        _addToDeposit(depositId_, amount_);

        emit Deposited(depositInfo[depositId_].depositor, recipientLookup[depositId_], amount_);
    }

    /**
        @notice Withdraw gOHM deposit from vault
        @param depositId_ Deposit ID to remove gOHM deposit from
        @param amount_ Amount of gOHM deposit to remove and return to donor 
    */
    function _withdraw(uint256 depositId_, uint256 amount_) internal returns (uint256 amountWithdrawn) {
        if (isInvalidWithdrawal(amount_)) revert YieldDirector_InvalidWithdrawal();

        if (amount_ >= _toAgnostic(depositInfo[depositId_].principalAmount)) {
            amountWithdrawn = _withdrawAllPrincipal(depositId_);
        } else {
            _withdrawPrincipal(depositId_, amount_);
            amountWithdrawn = amount_;
        }

        emit Withdrawn(msg.sender, recipientLookup[depositId_], amountWithdrawn);
    }

    /**
        @notice Redeem available gOHM yield from a specific deposit
        @param depositId_ Deposit ID to withdraw gOHM yield from
    */
    function _redeem(uint256 depositId_) internal returns (uint256 amountRedeemed) {
        if (redeemDisabled) revert YieldDirector_RedeemsDisabled();
        if (recipientLookup[depositId_] != msg.sender) revert YieldDirector_NotYourDeposit();

        amountRedeemed = _redeemYield(depositId_);
        if (amountRedeemed == 0) revert YieldDirector_NoRedeemableBalance();

        if (depositInfo[depositId_].principalAmount == 0) {
            _closeDeposit(depositId_);

            uint256[] storage receiptIds = recipientIds[msg.sender];
            for (uint256 i = 0; i < receiptIds.length; ++i) {
                if (receiptIds[i] == depositId_) {
                    // Remove id from depositor's ids array
                    receiptIds[i] = receiptIds[receiptIds.length - 1]; // Delete integer from array by swapping with last element and calling pop()
                    receiptIds.pop();
                    break;
                }
            }

            delete recipientLookup[depositId_];
        }

        emit Redeemed(msg.sender, amountRedeemed);
        emit Donated(depositInfo[depositId_].depositor, msg.sender, amountRedeemed);
    }

    /**
        @notice Redeem all available gOHM yield from the vault
    */
    function _redeemAll() internal returns (uint256 amountRedeemed) {
        if (redeemDisabled) revert YieldDirector_RedeemsDisabled();

        amountRedeemed = 0;

        // Have to read the IDs into memory because with each redemption
        // an ID is removed from the state array
        uint256[] memory receiptIds = recipientIds[msg.sender];

        for (uint256 index = 0; index < receiptIds.length; ++index) {
            uint256 currRedemption = _redeem(receiptIds[index]);
            amountRedeemed += currRedemption;

            emit Donated(depositInfo[receiptIds[index]].depositor, msg.sender, currRedemption);
        }

        emit Redeemed(msg.sender, amountRedeemed);
    }

    /************************
     * Emergency Functions
     ************************/

    function emergencyShutdown(bool active_) external onlyGovernor {
        depositDisabled = active_;
        withdrawDisabled = active_;
        redeemDisabled = active_;
        emit EmergencyShutdown(active_);
    }

    function disableDeposits(bool active_) external onlyGovernor {
        depositDisabled = active_;
    }

    function disableWithdrawals(bool active_) external onlyGovernor {
        withdrawDisabled = active_;
    }

    function disableRedeems(bool active_) external onlyGovernor {
        redeemDisabled = active_;
    }
}