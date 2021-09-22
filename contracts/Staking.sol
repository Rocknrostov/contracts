// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1363Receiver} from "@openzeppelin/contracts/interfaces/IERC1363Receiver.sol";
import {IAccessControl, AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import "hardhat/console.sol";

import {StableThenToken} from "./staking/StableThenToken.sol";
import {IRewardParameters, RewardCalculator} from "./staking/RewardCalculator.sol";
import {ITalentToken} from "./TalentToken.sol";
import {ITalentFactory} from "./TalentFactory.sol";

/// Staking contract
///
/// @notice During phase 1, accepts USDT, which is automatically converted into an equivalent TAL amount.
///   Once phase 2 starts (after a TAL address has been set), only TAL deposits are accepted
///
/// @dev Across
contract Staking is AccessControl, StableThenToken, RewardCalculator, IERC1363Receiver {
    /// Details of each individual stake
    struct Stake {
        /// Owner of the stake
        address owner;
        /// Talent token the stake applies to
        address talent;
        /// Amount currently staked
        uint256 tokenAmount;
        /// Talent tokens minted as part of this stake
        uint256 talentAmount;
        /// Latest checkpoint for this stake. Staking rewards should only be
        /// calculated from this moment forward. Anything past it should already
        /// be accounted for in `tokenAmount`
        uint256 lastCheckpointAt;
    }

    /// List of all stakes (investor => Stake)
    mapping(address => Stake) public stakes;

    bytes4 constant ERC1363_RECEIVER_RET = bytes4(keccak256("onTransferReceived(address,address,uint256,bytes)"));

    /// The Talent Token Factory contract (ITalentFactory)
    address public factory;

    /// The price (in USD cents) of a single TAL token
    uint256 public tokenPrice;

    /// The price (in TAL tokens) of a single Talent Token
    uint256 public talentPrice;

    /// How much stablecoin was staked, but without yet depositing the expected TAL equivalent
    ///
    /// @notice After TAL is deployed, `swapStableForToken(uint256)` needs to be
    /// called by an admin, to withdraw any stable coin stored in the contract,
    /// and replace it with the TAL equivalent
    uint256 public totalStableStored;

    // How much TAL is currently staked (not including rewards)
    uint256 public totalTokenStaked;

    // How much TAL is to be given in rewards
    uint256 public immutable override(IRewardParameters) rewardsMax;

    // How much TAL has already been given/reserved in rewards
    uint256 public override(IRewardParameters) rewardsGiven;

    /// Start date for staking period
    uint256 public immutable override(IRewardParameters) start;

    /// End date for staking period
    uint256 public immutable override(IRewardParameters) end;

    /// @param _start Timestamp at which staking begins
    /// @param _end Timestamp at which staking ends
    /// @param _rewardsMax Total amount of TAL to be given in rewards
    /// @param _stableCoin The USD-pegged stable-coin contract to use
    /// @param _factory ITalentFactory instance
    /// @param _tokenPrice The price of a tal token in the give stable-coin (50 means 1 TAL = 0.50USD)
    /// @param _talentPrice The price of a talent token in TAL (50 means 1 Talent Token = 50 TAL)
    constructor(
        uint256 _start,
        uint256 _end,
        uint256 _rewardsMax,
        address _stableCoin,
        address _factory,
        uint256 _tokenPrice,
        uint256 _talentPrice
    ) StableThenToken(_stableCoin) {
        require(_tokenPrice > 0, "_tokenPrice cannot be 0");
        require(_talentPrice > 0, "_talentPrice cannot be 0");

        start = _start;
        end = _end;
        rewardsMax = _rewardsMax;
        factory = _factory;
        tokenPrice = _tokenPrice;
        talentPrice = _talentPrice;

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    modifier onlyWhileStakingEnabled() {
        require(block.timestamp >= start, "staking period not yet started");
        require(block.timestamp <= end, "staking period already finished");
        _;
    }

    /// Creates a new stake from an amount of stable coin.
    /// The USD amount will be converted to the equivalent amount in TAL, according to the pre-determined rate
    ///
    /// @param _amount The amount of stable coin to stake
    /// @return true if operation succeeds
    ///
    /// @notice The contract must be previously approved to spend _amount on behalf of `msg.sender`
    function stakeStable(address _talent, uint256 _amount)
        public
        onlyWhileStakingEnabled
        stablePhaseOnly
        returns (bool)
    {
        require(_amount > 0, "amount cannot be zero");

        IERC20(stableCoin).transferFrom(msg.sender, address(this), _amount);

        uint256 tokenAmount = convertUsdToToken(_amount);

        totalStableStored += _amount;

        _stake(msg.sender, _talent, tokenAmount);

        return true;
    }

    /// Calculates stable coin balance of the contract
    ///
    /// @return the stable coin balance
    function stableCoinBalance() public view returns (uint256) {
        return IERC20(stableCoin).balanceOf(address(this));
    }

    /// Calculates TAL token balance of the contract
    ///
    /// @return the amount of TAL tokens
    function tokenBalance() public view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// Deposits TAL in exchange for the equivalent amount of stable coin stored in the contract
    ///
    /// @notice Meant to be used by the contract owner to retrieve stable coin
    /// from phase 1, and provide the equivalent TAL amount expected from stakers
    ///
    /// @param _stableAmount amount of stable coin to be retrieved.
    ///
    /// @notice Corresponding TAL amount will be enforced based on the set price
    function swapStableForToken(uint256 _stableAmount) public onlyRole(DEFAULT_ADMIN_ROLE) tokenPhaseOnly {
        require(_stableAmount <= totalStableStored, "not enough stable coin left in the contract");

        uint256 tokenAmount = convertUsdToToken(_stableAmount);
        totalStableStored -= _stableAmount;

        IERC20(token).transferFrom(msg.sender, address(this), tokenAmount);
        IERC20(stableCoin).transfer(msg.sender, _stableAmount);
    }

    //
    // Begin: IERC1363Receiver
    //

    function onTransferReceived(
        address, // _operator
        address _sender,
        uint256 _amount,
        bytes calldata data
    ) external override(IERC1363Receiver) onlyWhileStakingEnabled returns (bytes4) {
        require(_isTokenToken(msg.sender) || _isTalentToken(msg.sender), "Unrecognized ERC20 token received");

        if (_isTokenToken(msg.sender)) {
            // if input is TAL, this is a stake since TAL deposits are enabled when
            // `setToken` is called, no additional check for `tokenPhaseOnly` is
            // necessary here
            address talent = bytesToAddress(data);

            _stake(_sender, talent, _amount);

            return ERC1363_RECEIVER_RET;
        } else if (_isTalentToken(msg.sender)) {
            require(_isTokenSet(), "TAL token not yet set. Refund not possible");

            // if it's a registered Talent Token, this is a refund
            address talent = msg.sender;

            _unstake(_sender, talent, _amount);

            return ERC1363_RECEIVER_RET;
        } else {
            revert("Unrecognized ERC1363 token received");
        }
    }

    function _isTokenToken(address _address) internal view returns (bool) {
        return _address == token;
    }

    function _isTalentToken(address _address) internal view returns (bool) {
        return ITalentFactory(factory).isTalentToken(_address);
    }

    //
    // End: IERC1363Receivber
    //

    //
    // Begin: IRewardParameters
    //

    function totalShares() public view override(IRewardParameters) returns (uint256) {
        return totalTokenStaked;
    }

    function rewardsLeft() public view override(IRewardParameters) returns (uint256) {
        return rewardsMax - rewardsGiven;
    }

    //
    // End: IRewardParameters
    //

    //
    // Private Interface
    //

    /// Creates a stake, given an owner and a TAL amount
    ///
    /// @dev This function assumes tokens have been previously transfered by
    ///   the caller function or via ERC1363Receiver
    function _stake(
        address _owner,
        address _talent,
        uint256 _tokenAmount
    ) private {
        require(_isTalentToken(_talent), "not a valid talent token");
        require(stakes[_owner].owner == address(0x0), "address already has stake");
        require(_tokenAmount > 0, "amount cannot be zero");

        uint256 talentAmount = convertTokenToTalent(_tokenAmount);

        stakes[_owner] = Stake(_owner, _talent, _tokenAmount, talentAmount, block.timestamp);
        totalTokenStaked = _tokenAmount;

        _mintTalent(_owner, _talent, talentAmount);
    }

    function _unstake(
        address _owner,
        address _talent,
        uint256 _talentAmount
    ) private {
        require(_isTalentToken(_talent), "not a valid talent token");

        Stake storage stake = stakes[_owner];

        require(stake.owner == _owner, "stake does not exist");
        require(stake.talentAmount == _talentAmount);

        // TODO missing rewards calculation
        require(IERC20(token).balanceOf(address(this)) >= stake.tokenAmount, "not enough TAL to fulfill request");

        _burnTalent(_talent, _talentAmount);
        _withdrawToken(stake.owner, stake.tokenAmount);

        // stake.finished = true;

        // TODO? do we only allow refunds for 100% of the talent tokens received?
    }

    /// mints a given amount of a given talent token
    /// to be used within a staking update (re-stake or new deposit)
    ///
    /// @notice The staking update itself is assumed to happen on the caller
    function _mintTalent(
        address _owner,
        address _talent,
        uint256 _amount
    ) private {
        ITalentToken(_talent).mint(_owner, _amount);
    }

    /// burns a given amount of a given talent token
    /// to be used within a staking update (withdrawal or refund)
    ///
    /// @notice The staking update itself is assumed to happen on the caller
    ///
    /// @notice Since withdrawal functions work via ERC1363 and receive the
    /// Talent token prior to calling `onTransferReceived`, /   by this point,
    /// the contract is the owner of the tokens to be burnt, not the owner
    function _burnTalent(address _talent, uint256 _amount) private {
        ITalentToken(_talent).burn(address(this), _amount);
    }

    /// returns a given amount of TAL to an owner
    function _withdrawToken(address _owner, uint256 _amount) private {
        IERC20(token).transfer(_owner, _amount);
    }

    /// Converts a given USD amount to TAL
    ///
    /// @param _usd The amount of USD, in cents, to convert
    /// @return The converted TAL amount
    function convertUsdToToken(uint256 _usd) public view returns (uint256) {
        return (_usd / tokenPrice) * 1 ether;
    }

    /// Converts a given TAL amount to a Talent Token amount
    ///
    /// @param _tal The amount of TAL to convert
    /// @return The converted Talent Token amount
    function convertTokenToTalent(uint256 _tal) public view returns (uint256) {
        return (_tal / talentPrice) * 1 ether;
    }

    /// Converts a given Talent Token amount to TAL
    ///
    /// @param _talent The amount of Talent Tokens to convert
    /// @return The converted TAL amount
    function convertTalentToToken(uint256 _talent) public view returns (uint256) {
        return (_talent * talentPrice) / 1 ether;
    }

    /// Converts a given USD amount to Talent token
    ///
    /// @param _usd The amount of USD, in cents, to convert
    /// @return The converted Talent token amount
    function convertUsdToTalent(uint256 _usd) public view returns (uint256) {
        return convertTokenToTalent(convertUsdToToken(_usd));
    }

    /// Converts a byte sequence to address
    ///
    /// @dev This function requires the byte sequence to have 20 bytes of length
    ///
    /// @dev I didn't understand why using `calldata` instead of `memory` doesn't work,
    ///   or what would be the correct assembly to work with it.
    function bytesToAddress(bytes memory bs) private pure returns (address addr) {
        require(bs.length == 20, "invalid data length for address");

        assembly {
            addr := mload(add(bs, 20))
        }
    }
}
