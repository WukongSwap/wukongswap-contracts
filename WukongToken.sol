// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
import "hardhat/console.sol";
import "./libs/BEP20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";


// WukongToken with Governance.
contract WukongToken is BEP20 {
    // Transfer tax rate in basis points. (default 5%)
    uint16 public transferTaxRate = 500;
    // Burn rate % of transfer tax. (default 20% x 5% = 1% of total amount).
    uint16 public burnRate = 20;
    // Max transfer tax rate: 10%.
    uint16 public constant MAXIMUM_TRANSFER_TAX_RATE = 1000;
    // Burn address
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    // BUSD address
    address public constant BUSD_ADDRESS = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;

    // Max transfer amount rate in basis points. (default is 0.5% of total supply)
    uint16 public maxTransferAmountRate = 50;
    // Addresses that excluded from antiWhale
    mapping(address => bool) private _excludedFromAntiWhale;
    // Addresses banned from swapping out for quick access.
    mapping(address => bool) private _includeToBlackList;
    // Addresses that got banned stored in array for frontend access.
    address[] private blackListArray;

    // Addresses that excluded from antiBot
    mapping(address => bool) private _excludedFromAntiBot;
    // time antiBot was activated
    uint256 public startTime;
    // base amount users can hold 3.5%
    uint256 public baseBuyable = 350;
    // minimum base amount users can hold 1.5%
    uint256 public minBaseBuyable = 150;

    // Automatic swap and liquify enabled
    bool public swapAndLiquifyEnabled = false;
    // antiBot enabled
    bool public antiBotActive = false;
    // Min amount to liquify. (default 500 Wukong)
    uint256 public minAmountToLiquify = 500 ether;
    // The swap router
    IUniswapV2Router02 public WukongSwapRouter;
    // The trading pairs
    address public WukongSwapPairBNB;
    address public WukongSwapPairBUSD;

    // In swap and liquify
    bool private _inSwapAndLiquify;

    // The operator can only update the transfer tax rate
    address private _operator;

    // Events
    event OperatorTransferred(address indexed previousOperator, address indexed newOperator);
    event TransferTaxRateUpdated(address indexed operator, uint256 previousRate, uint256 newRate);
    event BurnRateUpdated(address indexed operator, uint256 previousRate, uint256 newRate);
    event MaxTransferAmountRateUpdated(address indexed operator, uint256 previousRate, uint256 newRate);
    event AntiBotEnabled(address indexed operator);
    event SwapAndLiquifyEnabledUpdated(address indexed operator, bool enabled);
    event MinAmountToLiquifyUpdated(address indexed operator, uint256 previousAmount, uint256 newAmount);
    event WukongSwapRouterUpdated(address indexed operator, address indexed router, address indexed pair);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 ethReceived, uint256 tokensIntoLiqudity);

    modifier onlyOperator() {
        require(_operator == msg.sender, "operator: caller is not the operator");
        _;
    }

    modifier lockTheSwap {
        _inSwapAndLiquify = true;
        _;
        _inSwapAndLiquify = false;
    }

    modifier transferTaxFree {
        uint16 _transferTaxRate = transferTaxRate;
        transferTaxRate = 0;    
        _;
        transferTaxRate = _transferTaxRate;
    }

    modifier antiWhale(address sender, address recipient, uint256 amount) {
        if (maxTransferAmount() > 0) {
            if (
                _excludedFromAntiWhale[sender] == false
                && _excludedFromAntiWhale[recipient] == false
            ) {
                require(amount <= maxTransferAmount(), "WUKONG::antiWhale: Transfer amount exceeds the maxTransferAmount");
            }
        }
        _;
    }

    modifier antiBot(address sender, address recipient, uint256 amount) {
        if (antiBotActive == false) {
            // When antiBot is not active, only accept transfers from operator(To add liquidity). This is to 
            // prevent the bots from buying before antiBot is active, while still allowing
            // devs/operator to add the initial liquidity.
            require(sender == operator(), "WUKONG::antiBot: Transfers can only be done by operator.");
        } else if (antiBotActive == true && _excludedFromAntiBot[recipient] == false) {
            //reject if amount exceeds current limit.
            if (amount + balanceOf(recipient) <= maxBuyableAmount()) {
                autoSetIncludeToBlackList(recipient);
            }
        }
        _;
    }

    modifier blackList(address sender, address recipent) {
        require(_includeToBlackList[sender] == false,"WUKONG::blackList: You have been blacklisted as a bot (SENDER)");
        require(_includeToBlackList[recipent] == false,"WUKONG::blackList: You have been blacklisted as a bot (RECIPENT)");
        _;
    }

    /**
     * @notice Constructs the WukongToken contract.
     */
    constructor() public BEP20("WukongSwap Token", "WUKONG") {
        _operator = _msgSender();
        emit OperatorTransferred(address(0), _operator);

        _excludedFromAntiWhale[msg.sender] = true;
        _excludedFromAntiWhale[address(0)] = true;
        _excludedFromAntiWhale[address(this)] = true;
        _excludedFromAntiWhale[BURN_ADDRESS] = true;
    }

    /// @notice Creates `_amount` token to `_to`. Must only be called by the owner (MasterChef).
    function mint(address _to, uint256 _amount) public onlyOwner {
        _mint(_to, _amount);
        _moveDelegates(address(0), _delegates[_to], _amount);
    }

    /// @dev overrides transfer function to meet tokenomics of TEST
    function _transfer(address sender, address recipient, uint256 amount) internal virtual override antiBot(sender, recipient, amount) blackList(sender, recipient) antiWhale(sender, recipient, amount) {
        // swap and liquify
        if (
            swapAndLiquifyEnabled == true
            && _inSwapAndLiquify == false
            && address(WukongSwapRouter) != address(0)
            && WukongSwapPairBNB != address(0)
            && WukongSwapPairBUSD != address(0)
            && sender != WukongSwapPairBNB
            && sender != WukongSwapPairBUSD
            && sender != owner()
        ) {
            swapAndLiquify();
        }
        
        if (recipient == BURN_ADDRESS || transferTaxRate == 0) {
            super._transfer(sender, recipient, amount);
        } else {
            // default tax is 5% of every transfer
            uint256 taxAmount = amount.mul(transferTaxRate).div(10000);
            uint256 burnAmount = taxAmount.mul(burnRate).div(100);
            uint256 liquidityAmount = taxAmount.sub(burnAmount);
            require(taxAmount == burnAmount + liquidityAmount, "WUKONG::transfer: Burn value invalid");

            // default 95% of transfer sent to recipient
            uint256 sendAmount = amount.sub(taxAmount);
            require(amount == sendAmount + taxAmount, "WUKONG::transfer: Tax value invalid");

            super._transfer(sender, BURN_ADDRESS, burnAmount);
            super._transfer(sender, address(this), liquidityAmount);
            super._transfer(sender, recipient, sendAmount);
            amount = sendAmount;
        }
    }

    /// @dev Swap and liquify
    function swapAndLiquify() private lockTheSwap transferTaxFree {
        uint256 contractTokenBalance = balanceOf(address(this));
        uint256 maxTransferAmount = maxTransferAmount();
        contractTokenBalance = contractTokenBalance > maxTransferAmount ? maxTransferAmount : contractTokenBalance;
        
        if (contractTokenBalance >= minAmountToLiquify) {
            // only min amount to liquify
            uint256 liquifyAmount = minAmountToLiquify;

            // split the liquify amount into halves
            uint256 half = liquifyAmount.div(2);
            uint256 otherHalf = liquifyAmount.sub(half);

            // capture the contract's current ETH balance.
            // this is so that we can capture exactly the amount of ETH that the
            // swap creates, and not make the liquidity event include any ETH that
            // has been manually sent to the contract
            uint256 initialBalance = address(this).balance;

            // swap tokens for ETH
            swapTokensForEth(half);

            // how much ETH did we just swap into?
            uint256 newBalance = address(this).balance.sub(initialBalance);

            // add liquidity
            addLiquidity(otherHalf, newBalance);

            emit SwapAndLiquify(half, newBalance, otherHalf);
        }
    }

    /// @dev Swap tokens for eth
    function swapTokensForEth(uint256 tokenAmount) private {
        // generate the testSwap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WukongSwapRouter.WETH();

        _approve(address(this), address(WukongSwapRouter), tokenAmount);

        // make the swap
        WukongSwapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    /// @dev Add liquidity
    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(WukongSwapRouter), tokenAmount);

        // add the liquidity
        WukongSwapRouter.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            operator(),
            block.timestamp
        );
    }

    /**
     * @dev Returns the max buyable amount in percentage.
     */
    function maxBuyableAmount() public view returns (uint256) {
        //Fancy math to create a asymtotic curve
        uint256 timelapsedHour = (block.timestamp - startTime) / 3600;
        uint256 percentage = -((1000-baseBuyable)*-(timelapsedHour)) / (timelapsedHour+3) + baseBuyable;
        //Assuming baseBuyable is 3%
        //0 h -> 3%
        //1 h -> 6.13%
        //2 h -> 9.0625%
        //10 h -> 27.25%
        return totalSupply().mul(percentage).div(10000);
    }

    /**
     * @dev Returns the max transfer amount
     */
    function maxTransferAmount() public view returns (uint256) {
        return totalSupply().mul(maxTransferAmountRate).div(10000);
    }

    /**
     * @dev Returns the list of blacklisted users.
     */
    function fetchBlackListedUsers() public view returns (address[] memory) {
        return blackListArray;
    }

    /**
     * @dev Returns the address is excluded from antiWhale or not.
     */
    function isExcludedFromAntiBot(address _account) public view returns (bool) {
        return _excludedFromAntiBot[_account];
    }

    /**
     * @dev Returns the address is excluded from antiWhale or not.
     */
    function isExcludedFromAntiWhale(address _account) public view returns (bool) {
        return _excludedFromAntiWhale[_account];
    }


    // To receive BNB from WukongSwapRouter when swapping
    receive() external payable {}

    /**
     * @dev enable the AntiBot.
     * Can only be called by the current operator.
     * Important! Make sure ownership transferred to masterChef and router has been added
     * before activating.
     */
    function enableAntiBot() public onlyOperator {
        //Only activated once at launch. Users will only be able to Buy/Sell/Add Liquidity once antiBot is enabled.
        require(address(WukongSwapRouter) != address(0), "WUKONG::enableAntiBot: Router not yet added.");
        require(antiBotActive == false, "WUKONG::enableAntiBot: Already activated.");
        _excludedFromAntiBot[address(0)] = true;
        _excludedFromAntiBot[address(this)] = true;
        _excludedFromAntiBot[BURN_ADDRESS] = true;
        _excludedFromAntiBot[owner()] = true;
        _excludedFromAntiBot[address(WukongSwapRouter)] = true;
        _excludedFromAntiBot[WukongSwapPairBNB] = true;
        _excludedFromAntiBot[WukongSwapPairBUSD] = true;
        startTime = block.timestamp;
        antiBotActive = true;
        emit AntiBotEnabled(msg.sender);
    }

    /**
     * @dev Exclude an address from blackList.
     * Can only be called by the current operator.
     */
    function setExcludeFromBlackList(address _account) public onlyOperator {
        if (_includeToBlackList[_account] = true) {
            _includeToBlackList[_account] = false;
            //Remove the account from the array.
            for (uint i = 0; i < blackListArray.length; i++) {
                address toExclude = blackListArray[i];
                if (toExclude == _account) {
                    blackListArray[i] = blackListArray[blackListArray.length - 1];
                    blackListArray.pop();
                    break;
                }
            }
        }
    }

    /**
     * @dev Include an address to blackList.
     * Can only be called by the current operator for manual banning.
     */
    function manualSetIncludeToBlackList(address _account) public onlyOperator {
        if (_includeToBlackList[_account] == false) {
            _includeToBlackList[_account] = true;
            blackListArray.push(_account);
        }
    }

    /**
     * @dev Include an address to blackList.
     * This will be used for automatic banning.
     */
    function autoSetIncludeToBlackList(address _account) private {
        if (_includeToBlackList[_account] == false) {
            _includeToBlackList[_account] = true;
            blackListArray.push(_account);
        }
    }

    /**
     * @dev Change the base buyable.
     * This can only be called if antiBot is not active.
     * If untouched, base buyable will continue to be at 3.5%
     * We added a restriction to prevent baseBuyable from going too low.
     */
    function updatebaseBuyable(uint256 _baseBuyable) public onlyOperator {
        require(_baseBuyable >= minBaseBuyable, "WUKONG::updatebaseBuyable: baseBuyable is too low.");
        require(antiBotActive == false, "WUKONG::updatebaseBuyable: AntiBot is active, can't change base buyable now.");
        baseBuyable = _baseBuyable;
    }

    /**
     * @dev Update the swap router.
     * Can only be called by the current operator.
     */
    function updateWukongSwapRouter(address _router) public onlyOperator {
        WukongSwapRouter = IUniswapV2Router02(_router);
        WukongSwapPairBNB = IUniswapV2Factory(WukongSwapRouter.factory()).getPair(address(this), WukongSwapRouter.WETH());
        WukongSwapPairBUSD = IUniswapV2Factory(WukongSwapRouter.factory()).getPair(address(this), BUSD_ADDRESS);
        require(WukongSwapPairBNB != address(0), "WUKONG::updateWukongSwapRouter: Invalid pair address.");
        require(WukongSwapPairBUSD != address(0), "WUKONG::updateWukongSwapRouter: Invalid pair address.");
        emit WukongSwapRouterUpdated(msg.sender, address(WukongSwapRouter), WukongSwapPairBNB);
        emit WukongSwapRouterUpdated(msg.sender, address(WukongSwapRouter), WukongSwapPairBUSD);
    }

    /**
     * @dev Update the transfer tax rate.
     * Can only be called by the current operator.
     */
    function updateTransferTaxRate(uint16 _transferTaxRate) public onlyOperator {
        require(_transferTaxRate <= MAXIMUM_TRANSFER_TAX_RATE, "WUKONG::updateTransferTaxRate: Transfer tax rate must not exceed the maximum rate.");
        emit TransferTaxRateUpdated(msg.sender, transferTaxRate, _transferTaxRate);
        transferTaxRate = _transferTaxRate;
    }

    /**
     * @dev Update the burn rate.
     * Can only be called by the current operator.
     */
    function updateBurnRate(uint16 _burnRate) public onlyOperator {
        require(_burnRate <= 100, "WUKONG::updateBurnRate: Burn rate must not exceed the maximum rate.");
        emit BurnRateUpdated(msg.sender, burnRate, _burnRate);
        burnRate = _burnRate;
    }

    /**
     * @dev Update the max transfer amount rate.
     * Can only be called by the current operator.
     */
    function updateMaxTransferAmountRate(uint16 _maxTransferAmountRate) public onlyOperator {
        require(_maxTransferAmountRate <= 10000, "WUKONG::updateMaxTransferAmountRate: Max transfer amount rate must not exceed the maximum rate.");
        emit MaxTransferAmountRateUpdated(msg.sender, maxTransferAmountRate, _maxTransferAmountRate);
        maxTransferAmountRate = _maxTransferAmountRate;
    }

    /**
     * @dev Update the min amount to liquify.
     * Can only be called by the current operator.
     */
    function updateMinAmountToLiquify(uint256 _minAmount) public onlyOperator {
        emit MinAmountToLiquifyUpdated(msg.sender, minAmountToLiquify, _minAmount);
        minAmountToLiquify = _minAmount;
    }

    /**
     * @dev Exclude or include an address from antiWhale.
     * Can only be called by the current operator.
     */
    function setExcludedFromAntiWhale(address _account, bool _excluded) public onlyOperator {
        _excludedFromAntiWhale[_account] = _excluded;
    }

    /**
     * @dev Update the swapAndLiquifyEnabled.
     * Can only be called by the current operator.
     */
    function updateSwapAndLiquifyEnabled(bool _enabled) public onlyOperator {
        emit SwapAndLiquifyEnabledUpdated(msg.sender, _enabled);
        swapAndLiquifyEnabled = _enabled;
    }

    /**
     * @dev Returns the address of the current operator.
     */
    function operator() public view returns (address) {
        return _operator;
    }

    /**
     * @dev Transfers operator of the contract to a new account (`newOperator`).
     * Can only be called by the current operator.
     */
    function transferOperator(address newOperator) public onlyOperator {
        require(newOperator != address(0), "WUKONG::transferOperator: new operator is the zero address");
        emit OperatorTransferred(_operator, newOperator);
        _operator = newOperator;
    }

    // Copied and modified from YAM code:
    // https://github.com/yam-finance/yam-protocol/blob/master/contracts/token/YAMGovernanceStorage.sol
    // https://github.com/yam-finance/yam-protocol/blob/master/contracts/token/YAMGovernance.sol
    // Which is copied and modified from COMPOUND:
    // https://github.com/compound-finance/compound-protocol/blob/master/contracts/Governance/Comp.sol

    /// @dev A record of each accounts delegate
    mapping (address => address) internal _delegates;

    /// @notice A checkpoint for marking number of votes from a given block
    struct Checkpoint {
        uint32 fromBlock;
        uint256 votes;
    }

    /// @notice A record of votes checkpoints for each account, by index
    mapping (address => mapping (uint32 => Checkpoint)) public checkpoints;

    /// @notice The number of checkpoints for each account
    mapping (address => uint32) public numCheckpoints;

    /// @notice The EIP-712 typehash for the contract's domain
    bytes32 public constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    /// @notice The EIP-712 typehash for the delegation struct used by the contract
    bytes32 public constant DELEGATION_TYPEHASH = keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    /// @notice A record of states for signing / validating signatures
    mapping (address => uint) public nonces;

      /// @notice An event thats emitted when an account changes its delegate
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);

    /// @notice An event thats emitted when a delegate account's vote balance changes
    event DelegateVotesChanged(address indexed delegate, uint previousBalance, uint newBalance);
    

    /**
     * @notice Delegate votes from `msg.sender` to `delegatee`
     * @param delegator The address to get delegatee for
     */
    function delegates(address delegator)
        external
        view
        returns (address)
    {
        return _delegates[delegator];
    }

   /**
    * @notice Delegate votes from `msg.sender` to `delegatee`
    * @param delegatee The address to delegate votes to
    */
    function delegate(address delegatee) external {
        return _delegate(msg.sender, delegatee);
    }

    /**
     * @notice Delegates votes from signatory to `delegatee`
     * @param delegatee The address to delegate votes to
     * @param nonce The contract state required to match the signature
     * @param expiry The time at which to expire the signature
     * @param v The recovery byte of the signature
     * @param r Half of the ECDSA signature pair
     * @param s Half of the ECDSA signature pair
     */
    function delegateBySig(
        address delegatee,
        uint nonce,
        uint expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(name())),
                getChainId(),
                address(this)
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(
                DELEGATION_TYPEHASH,
                delegatee,
                nonce,
                expiry
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                structHash
            )
        );

        address signatory = ecrecover(digest, v, r, s);
        require(signatory != address(0), "WUKONG::delegateBySig: invalid signature");
        require(nonce == nonces[signatory]++, "WUKONG::delegateBySig: invalid nonce");
        require(now <= expiry, "WUKONG::delegateBySig: signature expired");
        return _delegate(signatory, delegatee);
    }

    /**
     * @notice Gets the current votes balance for `account`
     * @param account The address to get votes balance
     * @return The number of current votes for `account`
     */
    function getCurrentVotes(address account)
        external
        view
        returns (uint256)
    {
        uint32 nCheckpoints = numCheckpoints[account];
        return nCheckpoints > 0 ? checkpoints[account][nCheckpoints - 1].votes : 0;
    }

    /**
     * @notice Determine the prior number of votes for an account as of a block number
     * @dev Block number must be a finalized block or else this function will revert to prevent misinformation.
     * @param account The address of the account to check
     * @param blockNumber The block number to get the vote balance at
     * @return The number of votes the account had as of the given block
     */
    function getPriorVotes(address account, uint blockNumber)
        external
        view
        returns (uint256)
    {
        require(blockNumber < block.number, "WUKONG::getPriorVotes: not yet determined");

        uint32 nCheckpoints = numCheckpoints[account];
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (checkpoints[account][nCheckpoints - 1].fromBlock <= blockNumber) {
            return checkpoints[account][nCheckpoints - 1].votes;
        }

        // Next check implicit zero balance
        if (checkpoints[account][0].fromBlock > blockNumber) {
            return 0;
        }

        uint32 lower = 0;
        uint32 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint32 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints[account][center];
            if (cp.fromBlock == blockNumber) {
                return cp.votes;
            } else if (cp.fromBlock < blockNumber) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return checkpoints[account][lower].votes;
    }

    function _delegate(address delegator, address delegatee)
        internal
    {
        address currentDelegate = _delegates[delegator];
        uint256 delegatorBalance = balanceOf(delegator); // balance of underlying WUKONGs (not scaled);
        _delegates[delegator] = delegatee;

        emit DelegateChanged(delegator, currentDelegate, delegatee);

        _moveDelegates(currentDelegate, delegatee, delegatorBalance);
    }

    function _moveDelegates(address srcRep, address dstRep, uint256 amount) internal {
        if (srcRep != dstRep && amount > 0) {
            if (srcRep != address(0)) {
                // decrease old representative
                uint32 srcRepNum = numCheckpoints[srcRep];
                uint256 srcRepOld = srcRepNum > 0 ? checkpoints[srcRep][srcRepNum - 1].votes : 0;
                uint256 srcRepNew = srcRepOld.sub(amount);
                _writeCheckpoint(srcRep, srcRepNum, srcRepOld, srcRepNew);
            }

            if (dstRep != address(0)) {
                // increase new representative
                uint32 dstRepNum = numCheckpoints[dstRep];
                uint256 dstRepOld = dstRepNum > 0 ? checkpoints[dstRep][dstRepNum - 1].votes : 0;
                uint256 dstRepNew = dstRepOld.add(amount);
                _writeCheckpoint(dstRep, dstRepNum, dstRepOld, dstRepNew);
            }
        }
    }

    function _writeCheckpoint(
        address delegatee,
        uint32 nCheckpoints,
        uint256 oldVotes,
        uint256 newVotes
    )
        internal
    {
        uint32 blockNumber = safe32(block.number, "WUKONG::_writeCheckpoint: block number exceeds 32 bits");

        if (nCheckpoints > 0 && checkpoints[delegatee][nCheckpoints - 1].fromBlock == blockNumber) {
            checkpoints[delegatee][nCheckpoints - 1].votes = newVotes;
        } else {
            checkpoints[delegatee][nCheckpoints] = Checkpoint(blockNumber, newVotes);
            numCheckpoints[delegatee] = nCheckpoints + 1;
        }

        emit DelegateVotesChanged(delegatee, oldVotes, newVotes);
    }

    function safe32(uint n, string memory errorMessage) internal pure returns (uint32) {
        require(n < 2**32, errorMessage);
        return uint32(n);
    }

    function getChainId() internal pure returns (uint) {
        uint256 chainId;
        assembly { chainId := chainid() }
        return chainId;
    }
}
