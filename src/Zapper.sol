// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IWETH.sol";
import "./libs/Babylonian.sol";

contract Zapper {
    using SafeERC20 for IERC20;

    IUniswapV2Factory private constant UniSwapV2FactoryAddress =
        IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);

    IUniswapV2Router02 private constant uniswapRouter = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    address private constant wethTokenAddress = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    uint256 private constant deadline = 0xf000000000000000000000000000000000000000000000000000000000000000;

    event zapIn(address sender, address pool, uint256 tokensRec);

    /**
     * @notice This function is used to invest in given Uniswap V2 pair through ETH/ERC20 Tokens
     * @param _FromTokenContractAddress The ERC20 token used for investment (address(0x00) if ether)
     * @param _pairAddress The Uniswap pair address
     * @param _amount The amount of fromToken to invest
     * @param _minPoolTokens Reverts if less tokens received than this
     * @param _swapTarget Excecution target for the first swap
     * @param swapData DEX quote data
     * @param transferResidual Set false to save gas by donating the residual remaining after a Zap
     * @return Amount of LP bought
     */
    function ZapIn(
        address _FromTokenContractAddress,
        address _pairAddress,
        uint256 _amount,
        uint256 _minPoolTokens,
        address _swapTarget,
        bytes calldata swapData,
        bool transferResidual
    ) external payable returns (uint256) {
        _pullTokens(_FromTokenContractAddress, _amount);

        uint256 LPBought =
            _performZapIn(_FromTokenContractAddress, _pairAddress, _amount, _swapTarget, swapData, transferResidual);
        require(LPBought >= _minPoolTokens, "High Slippage");

        emit zapIn(msg.sender, _pairAddress, LPBought);

        IERC20(_pairAddress).safeTransfer(msg.sender, LPBought);
        return LPBought;
    }

    function _getPairTokens(address _pairAddress) internal pure returns (address token0, address token1) {
        IUniswapV2Pair uniPair = IUniswapV2Pair(_pairAddress);
        token0 = uniPair.token0();
        token1 = uniPair.token1();
    }

    function _performZapIn(
        address _FromTokenContractAddress,
        address _pairAddress,
        uint256 _amount,
        address _swapTarget,
        bytes memory swapData,
        bool transferResidual
    ) internal returns (uint256) {
        uint256 intermediateAmt;
        address intermediateToken;
        (address _ToUniswapToken0, address _ToUniswapToken1) = _getPairTokens(_pairAddress);

        if (_FromTokenContractAddress != _ToUniswapToken0 && _FromTokenContractAddress != _ToUniswapToken1) {
            // swap to intermediate
            (intermediateAmt, intermediateToken) =
                _fillQuote(_FromTokenContractAddress, _pairAddress, _amount, _swapTarget, swapData);
        } else {
            intermediateToken = _FromTokenContractAddress;
            intermediateAmt = _amount;
        }

        // divide intermediate into appropriate amount to add liquidity
        (uint256 token0Bought, uint256 token1Bought) =
            _swapIntermediate(intermediateToken, _ToUniswapToken0, _ToUniswapToken1, intermediateAmt);

        return _uniDeposit(_ToUniswapToken0, _ToUniswapToken1, token0Bought, token1Bought, transferResidual);
    }

    function _uniDeposit(
        address _ToUnipoolToken0,
        address _ToUnipoolToken1,
        uint256 token0Bought,
        uint256 token1Bought,
        bool transferResidual
    ) internal returns (uint256) {
        _approveToken(_ToUnipoolToken0, address(uniswapRouter), token0Bought);
        _approveToken(_ToUnipoolToken1, address(uniswapRouter), token1Bought);

        (uint256 amountA, uint256 amountB, uint256 LP) = uniswapRouter.addLiquidity(
            _ToUnipoolToken0, _ToUnipoolToken1, token0Bought, token1Bought, 1, 1, address(this), deadline
        );

        if (transferResidual) {
            //Returning Residue in token0, if any.
            if (token0Bought - amountA > 0) {
                IERC20(_ToUnipoolToken0).safeTransfer(msg.sender, token0Bought - amountA);
            }

            //Returning Residue in token1, if any
            if (token1Bought - amountB > 0) {
                IERC20(_ToUnipoolToken1).safeTransfer(msg.sender, token1Bought - amountB);
            }
        }

        return LP;
    }

    function _fillQuote(
        address _fromTokenAddress,
        address _pairAddress,
        uint256 _amount,
        address _swapTarget,
        bytes memory swapData
    ) internal returns (uint256 amountBought, address intermediateToken) {
        if (_swapTarget == wethTokenAddress) {
            IWETH(wethTokenAddress).deposit{value: _amount}();
            return (_amount, wethTokenAddress);
        }

        uint256 valueToSend;
        if (_fromTokenAddress == address(0)) {
            valueToSend = _amount;
        } else {
            _approveToken(_fromTokenAddress, _swapTarget, _amount);
        }

        (address _token0, address _token1) = _getPairTokens(_pairAddress);
        IERC20 token0 = IERC20(_token0);
        IERC20 token1 = IERC20(_token1);
        uint256 initialBalance0 = token0.balanceOf(address(this));
        uint256 initialBalance1 = token1.balanceOf(address(this));

        // @todo add a check here
        // require(approvedTargets[_swapTarget], "Target not Authorized");
        (bool success,) = _swapTarget.call{value: valueToSend}(swapData);
        require(success, "Error Swapping Tokens 1");

        uint256 finalBalance0 = token0.balanceOf(address(this)) - initialBalance0;
        uint256 finalBalance1 = token1.balanceOf(address(this)) - initialBalance1;

        if (finalBalance0 > finalBalance1) {
            amountBought = finalBalance0;
            intermediateToken = _token0;
        } else {
            amountBought = finalBalance1;
            intermediateToken = _token1;
        }

        require(amountBought > 0, "Swapped to Invalid Intermediate");
    }

    function _swapIntermediate(
        address _toContractAddress,
        address _ToUnipoolToken0,
        address _ToUnipoolToken1,
        uint256 _amount
    ) internal returns (uint256 token0Bought, uint256 token1Bought) {
        IUniswapV2Pair pair = IUniswapV2Pair(UniSwapV2FactoryAddress.getPair(_ToUnipoolToken0, _ToUnipoolToken1));
        (uint256 res0, uint256 res1,) = pair.getReserves();
        if (_toContractAddress == _ToUnipoolToken0) {
            uint256 amountToSwap = calculateSwapInAmount(res0, _amount);
            //if no reserve or a new pair is created
            if (amountToSwap <= 0) amountToSwap = _amount / 2;
            token1Bought = _token2Token(_toContractAddress, _ToUnipoolToken1, amountToSwap);
            token0Bought = _amount - amountToSwap;
        } else {
            uint256 amountToSwap = calculateSwapInAmount(res1, _amount);
            //if no reserve or a new pair is created
            if (amountToSwap <= 0) amountToSwap = _amount / 2;
            token0Bought = _token2Token(_toContractAddress, _ToUnipoolToken0, amountToSwap);
            token1Bought = _amount - amountToSwap;
        }
    }

    function calculateSwapInAmount(uint256 reserveIn, uint256 userIn) internal pure returns (uint256) {
        return (Babylonian.sqrt(reserveIn * ((userIn * 3988000) + (reserveIn * 3988009))) - (reserveIn * 1997)) / 1994;
    }

    /**
     * @notice This function is used to swap ERC20 <> ERC20
     * @param _FromTokenContractAddress The token address to swap from.
     * @param _ToTokenContractAddress The token address to swap to.
     * @param tokens2Trade The amount of tokens to swap
     * @return tokenBought The quantity of tokens bought
     */
    function _token2Token(address _FromTokenContractAddress, address _ToTokenContractAddress, uint256 tokens2Trade)
        internal
        returns (uint256 tokenBought)
    {
        if (_FromTokenContractAddress == _ToTokenContractAddress) {
            return tokens2Trade;
        }

        _approveToken(_FromTokenContractAddress, address(uniswapRouter), tokens2Trade);

        address pair = UniSwapV2FactoryAddress.getPair(_FromTokenContractAddress, _ToTokenContractAddress);
        require(pair != address(0), "No Swap Available");
        address[] memory path = new address[](2);
        path[0] = _FromTokenContractAddress;
        path[1] = _ToTokenContractAddress;

        tokenBought =
            uniswapRouter.swapExactTokensForTokens(tokens2Trade, 1, path, address(this), deadline)[path.length - 1];

        require(tokenBought > 0, "Error Swapping Tokens 2");
    }

    function _approveToken(address token, address spender) internal {
        IERC20 _token = IERC20(token);
        if (_token.allowance(address(this), spender) > 0) return;
        else _token.forceApprove(spender, type(uint256).max);
    }

    function _approveToken(address token, address spender, uint256 amount) internal {
        IERC20 _token = IERC20(token);
        _token.forceApprove(spender, 0);
        _token.forceApprove(spender, amount);
    }

    function _pullTokens(address token, uint256 amount) internal {
        if (token == address(0)) {
            require(msg.value > 0, "No eth sent");
        }
        require(amount > 0, "Invalid token amount");
        require(msg.value == 0, "Eth sent with token");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }
}
