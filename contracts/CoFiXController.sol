// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.6.6;

import "./lib/SafeMath.sol";
import "./lib/ABDKMath64x64.sol";
import "./interface/INest_3_OfferPrice.sol";
import "./interface/ICoFiXKTable.sol";
import './lib/TransferHelpers.sol';

// Controller contract to call NEST Oracle for prices, no special ownership
contract CoFiXController {

    using SafeMath for uint256;
    
    event newK(address token, int128 K, int128 sigma, uint256 T, uint256 ethAmount, uint256 erc20Amount, uint256 blockNum, uint256 tIdx, uint256 sigmaIdx, int128 K0);

    int128 constant public ALPHA = 0x1342825B8F72CF0; // (0.0047021*2**64).toString(16), 0.0047021 as 64.64-bit fixed point
    int128 constant public BETA_ONE = 0x35D7F9C779A6B6000000; // (13783.9757*2**64).toString(16), 13783.9757 as 64-bit fixed point
    int128 constant public BETA_TWO = 0x19A5EE66A57B7; // (2.446*10**(-5)*2**64).toString(16), 2.446*10**(-5) as 64.64-bit fixed point
    int128 constant public THETA = 0x83126E978D4FE0; // (0.002*2**64).toString(16), 0.002 as 64.64-bit fixed point

    int128 constant public SIGMA_STEP = 0x68DB8BAC710CB; // (0.0001*2**64).toString(16), 0.0001 as 64.64-bit fixed point
    int128 constant public ZERO_POINT_FIVE = 0x8000000000000000; // (0.5*2**64).toString(16), 0.5 as 64.64-bit fixed point
    int128 public GAMMA = 0x8000000000000000; // (0.5*2**64).toString(16), 0.5 as 64.64-bit fixed point

    uint256 constant public AONE = 1 ether;
    uint256 constant public K_BASE = 100000;
    uint256 constant public THETA_BASE = 10000;
    uint256 constant internal TIMESTAMP_MODULUS = 2**32;
    uint256 constant DESTRUCTION_AMOUNT = 10000 ether; // from nest oracle

    // TODO: setter for these variables
    uint256 public timespan_;
    int128 public MIN_K;
    int128 public MAX_K;
    int128 public MAX_K0;
    address public oracle;
    address public nestToken;
    address public governance;
    address public factory;
    address public kTable;

    bool public activated;

    mapping(address => uint32[3]) internal KInfoMap; // gas saving, index [0] is k vlaue, index [1] is updatedAt, index [2] is theta
    mapping(address => bool) public callerAllowed;

    // use uint32[2] instead
    // struct KInfo {
    //     uint256 k;
    //     uint256 updatedAt;
    //     uint256 theta;
    // }

    // use uint256[4] instead
    // struct OraclePrice {
    //     uint256 ethAmount;
    //     uint256 erc20Amount;
    //     uint256 blockNum;
    //     uint256 T;
    // }

    constructor(address _priceOracle, address _nest, address _factory, address _kTable) public {
        timespan_ = 14;
        MIN_K = 0x147AE147AE147B0; // (0.005*2**64).toString(16), 0.5% as 64.64-bit fixed point
        MAX_K = 0x1999999999999A00; // (0.1*2**64).toString(16),  10% as 64.64-bit fixed point
        MAX_K0 = 0xCCCCCCCCCCCCD00; // (0.05*2**64).toString(16),  5% as 64.64-bit fixed point
        oracle = _priceOracle;
        nestToken = _nest;
        governance = msg.sender;
        factory = _factory;
        kTable = _kTable;
    }

    receive() external payable {}

    function setGovernance(address _new) external {
        require(msg.sender == governance, "CFactory: !governance");
        governance = _new;
    }

    // TODO: Not sure to keep these setters
    // function setTimespan(uint256 _timeSpan) external {
    //     require(msg.sender == governance, "CFactory: !governance");
    //     timespan_ = _timeSpan;
    // }

    // function setKLimit(int128 min, int128 max) external {
    //     require(msg.sender == governance, "CFactory: !governance");
    //     MIN_K = min;
    //     MAX_K = max;
    // }

    function setTheta(address token, uint32 theta) external {
        require(msg.sender == governance, "CFactory: !governance");
        KInfoMap[token][2] = theta;
    }

    // Activate on NEST Oracle
    function activate() external {
        require(activated == false, "CoFiXCtrl: activated");
        // address token, address from, address to, uint value
        TransferHelper.safeTransferFrom(nestToken, msg.sender, address(this), DESTRUCTION_AMOUNT);
        // address token, address to, uint value
        TransferHelper.safeApprove(nestToken, oracle, DESTRUCTION_AMOUNT);
        INest_3_OfferPrice(oracle).activation(); // nest.transferFrom will be called
        TransferHelper.safeApprove(nestToken, oracle, 0); // ensure safety
        activated = true;
    }

    function addCaller(address caller) external {
        require(msg.sender == factory || msg.sender == governance, "CoFiXCtrl: only factory"); // omit governance in reason
        callerAllowed[caller] = true;
    }  

    function queryOracle(address token, address /*payback*/) external payable returns (uint256 _k, uint256, uint256, uint256, uint256) {
        require(callerAllowed[msg.sender] == true, "CoFiXCtrl: caller not allowed");
        uint256 _balanceBefore = address(this).balance;
        
        // int128 K0; // K0AndK[0]
        // int128 K; // K0AndK[1]
        int128[2] memory K0AndK;
        // TODO: cache K to reduce gas cost
        // OraclePrice memory _op;
        uint256[7] memory _op;
        int128 _variance;
        // (_variance, _op.T, _op.ethAmount, _op.erc20Amount, _op.blockNum) = calcVariance(token);
        (_variance, _op[0], _op[1], _op[2], _op[3]) = calcVariance(token);

        {
            // int128 _volatility = ABDKMath64x64.sqrt(_variance);
            // int128 _sigma = ABDKMath64x64.div(_volatility, ABDKMath64x64.sqrt(ABDKMath64x64.fromUInt(timespan_)));
            int128 _sigma = ABDKMath64x64.sqrt(ABDKMath64x64.div(_variance, ABDKMath64x64.fromUInt(timespan_))); // combined into one sqrt
            // // 𝐾 = α + β_1 * sigma^2  + β_2 * T
            // K = ABDKMath64x64.add(
            //                 ALPHA, 
            //                 ABDKMath64x64.add(
            //                     ABDKMath64x64.mul(BETA_ONE, ABDKMath64x64.pow(_sigma, 2)),
            //                     ABDKMath64x64.mul(BETA_TWO, ABDKMath64x64.fromUInt(_op[0]))
            //                 )
            //             );

            // tIdx is _op[4]
            // sigmaIdx is _op[5]
            _op[4] = (_op[0].add(5)).div(10); // rounding to the nearest
            _op[5] = ABDKMath64x64.toUInt(
                        ABDKMath64x64.add(
                            ABDKMath64x64.div(_sigma, SIGMA_STEP), // _sigma / 0.0001, e.g. (0.00098/0.0001)=9.799 => 9
                            ZERO_POINT_FIVE // e.g. (0.00098/0.0001)+0.5=10.299 => 10
                        )
                    );
            if (_op[5] >= 1) {
                _op[5] = _op[5].sub(1);
            }

            require(_op[4] <= 90, "CoFiXCtrl: tIdx must <= 91");
            require(_op[5] <= 30, "CoFiXCtrl: sigmaIdx must <= 30");

            // getK0(uint256 tIdx, uint256 sigmaIdx)
            // K0 is K0AndK[0]
            K0AndK[0] = ICoFiXKTable(kTable).getK0(
                _op[4], 
                _op[5]
            );

            // K = gamma * K0
            K0AndK[1] = ABDKMath64x64.mul(GAMMA, K0AndK[0]);

            emit newK(token, K0AndK[1], _sigma, _op[0], _op[1], _op[2], _op[3], _op[4], _op[5], K0AndK[0]);
        }

        require(K0AndK[0] <= MAX_K0, "CoFiXCtrl: K0");

        if (K0AndK[1] < MIN_K) {
            K0AndK[1] = MIN_K;
        } else if (K0AndK[1] > MAX_K) {
            revert("CoFiXCtrl: K");
        }

        {
            // TODO: payback param ununsed now
            // we could use this to pay the fee change and mining award token directly to reduce call cost
            // TransferHelper.safeTransferETH(payback, msg.value.sub(_balanceBefore.sub(address(this).balance)));
            TransferHelper.safeTransferETH(msg.sender, msg.value.sub(_balanceBefore.sub(address(this).balance)));
            _k = ABDKMath64x64.toUInt(ABDKMath64x64.mul(K0AndK[1], ABDKMath64x64.fromUInt(K_BASE)));
            // _op[6] = ABDKMath64x64.toUInt(ABDKMath64x64.mul(KInfoMap[token][2], ABDKMath64x64.fromUInt(THETA_BASE))); // theta
            _op[6] = KInfoMap[token][2]; // theta
            KInfoMap[token][0] = uint32(_k); // k < MAX_K << uint32(-1)
            KInfoMap[token][1] = uint32(block.timestamp % TIMESTAMP_MODULUS); // 2106
            return (_k, _op[1], _op[2], _op[3], _op[6]);
        }
    }

    function getKInfo(address token) public view returns (uint32 k, uint32 updatedAt, uint32 theta) {
        k = KInfoMap[token][0];
        updatedAt = KInfoMap[token][1];
        theta = KInfoMap[token][2];
    }

    // TODO: oracle & token could be state varaibles
     // calc Variance, a.k.a. sigma squared
    function calcVariance(address token) internal returns (int128 _variance, uint256 _T, uint256 _ethAmount, uint256 _erc20Amount, uint256 _blockNum) {

        // query raw price list from nest oracle (newest to oldest)
        uint256[] memory _rawPriceList = INest_3_OfferPrice(oracle).updateAndCheckPriceList{value: msg.value}(token, 50);
        require(_rawPriceList.length == 150, "CoFiXCtrl: bad price len");
        // calc P a.k.a. price from the raw price data (ethAmount, erc20Amount, blockNum)
        uint256[] memory _prices = new uint256[](50);
        for (uint256 i = 0; i < 50; i++) {
            // 0..50 (newest to oldest), so _prices[0] is p49 (latest price), _prices[49] is p0 (base price)
            _prices[i] = calcPrice(_rawPriceList[i*3], _rawPriceList[i*3+1]);
        }

        // calc x a.k.a. standardized sequence of differences (newest to oldest)
        int128[] memory _stdSeq = new int128[](49);
        for (uint256 i = 0; i < 49; i++) {
            _stdSeq[i] = calcStdSeq(_prices[i], _prices[i+1], _prices[49], _rawPriceList[i*3+2], _rawPriceList[(i+1)*3+2]);
        }

        // Option 1: calc variance of x
        int128 _sumSq; // sum of squares of x
        int128 _sum; // sum of x
        for (uint256 i = 0; i < 49; i++) {
            _sumSq = ABDKMath64x64.add(ABDKMath64x64.pow(_stdSeq[i], 2), _sumSq);
            _sum = ABDKMath64x64.add(_stdSeq[i], _sum);
        }
        _variance = ABDKMath64x64.sub(
            ABDKMath64x64.div(
                _sumSq,
                ABDKMath64x64.fromUInt(49)
            ),
            ABDKMath64x64.div(
                ABDKMath64x64.pow(_sum, 2),
                ABDKMath64x64.fromUInt(49*49)
            )
        );

        // // Option 2: calc mean value first and then calc variance
        // int128 _sum; // suppose each stdEarningRate should be small or we'll calc mean vlaue in another way. TODO: validate
        // for (uint256 i = 0; i < 49; i++) {
        //     _sum = ABDKMath64x64.add(_stdSeq[i], _sum);
        // }
        // int128 _mean = ABDKMath64x64.div(_sum, ABDKMath64x64.fromUInt(49));
        // int128 _tmp;
        // for (uint256 i = 0; i < 49; i++) {
        //     _tmp = ABDKMath64x64.sub(_stdSeq[i], _mean);
        //     _variance = ABDKMath64x64.add(_variance, ABDKMath64x64.pow(_tmp, 2));
        // }
        // _variance = ABDKMath64x64.div(_variance, ABDKMath64x64.fromUInt(49));
        
        _T = block.number.sub(_rawPriceList[2]).mul(timespan_);
        return (_variance, _T, _rawPriceList[0], _rawPriceList[1], _rawPriceList[2]);
    }

    function calcPrice(uint256 _ethAmount, uint256 _erc20Amount) internal pure returns (uint256) {
        return AONE.mul(_erc20Amount).div(_ethAmount);
    }

    // diff ratio could be negative
    // p2: P_{i}
    // p1: P_{i-1}
    // p0: P_{0}
    function calcDiffRatio(uint256 p2, uint256 p1, uint256 p0) internal pure returns (int128) {
        int128 _p2 = ABDKMath64x64.fromUInt(p2);
        int128 _p1 = ABDKMath64x64.fromUInt(p1);
        int128 _p0 = ABDKMath64x64.fromUInt(p0);
        return ABDKMath64x64.div(ABDKMath64x64.sub(_p2, _p1), _p0);
    }

    // p2: P_{i}
    // p1: P_{i-1}
    // p0: P_{0}
    // bn2: blocknum_{i}
    // bn1: blocknum_{i-1}
    function calcStdSeq(uint256 p2, uint256 p1, uint256 p0, uint256 bn2, uint256 bn1) internal pure returns (int128) {
        return ABDKMath64x64.div(
                calcDiffRatio(p2, p1, p0),
                ABDKMath64x64.sqrt(
                    ABDKMath64x64.fromUInt(bn2.sub(bn1)) // c must be larger than d
                )
            );
    }
}