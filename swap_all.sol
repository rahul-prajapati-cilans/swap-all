// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SwapAllToETH {
    IUniswapV2Router02 public immutable uniswapRouter;
    address public immutable WETH;

    event TokenSwapped(
        address indexed user,
        address indexed token,
        uint256 amountIn,
        uint256 minAmountOut
    );

    constructor(address _router, address _weth) {
        uniswapRouter = IUniswapV2Router02(_router);
        WETH = _weth;
    }

    function swapAllTokensToETH(address[] calldata tokens, uint256 slippageBps) external {
        require(slippageBps <= 10_000, "Slippage too high");

        for (uint256 i = 0; i < tokens.length; i++) {
            address tokenAddress = tokens[i];
            IERC20 token = IERC20(tokenAddress);

            uint256 userBalance = token.balanceOf(msg.sender);
            if (userBalance == 0) continue;

            // Attempt transferFrom using low-level call to support non-standard tokens
            (bool success, bytes memory data) = tokenAddress.call(
                abi.encodeWithSelector(token.transferFrom.selector, msg.sender, address(this), userBalance)
            );

            bool transferOK = success && (data.length == 0 || abi.decode(data, (bool)));
            if (!transferOK) continue;

            // Check received amount (handles taxed tokens)
            uint256 received = token.balanceOf(address(this));
            if (received == 0) continue;

            // Approve router if needed
            if (token.allowance(address(this), address(uniswapRouter)) < received) {
                try token.approve(address(uniswapRouter), type(uint256).max) {} catch {
                    // USDT-style: must reset to 0 before approving
                    try token.approve(address(uniswapRouter), 0) {
                        token.approve(address(uniswapRouter), type(uint256).max);
                    } catch {
                        continue; // Skip if both approve attempts fail
                    }
                }
            }

            address[] memory path = new address[](2);
            path[0] = tokenAddress;
            path[1] = WETH;

            uint256[] memory amountsOut;
            try uniswapRouter.getAmountsOut(received, path) returns (uint256[] memory out) {
                amountsOut = out;
            } catch {
                continue; // Skip if price quote fails
            }

            if (amountsOut.length < 2) continue;

            uint256 minOut = (amountsOut[1] * (10_000 - slippageBps)) / 10_000;

            // Attempt the swap, supporting fee-on-transfer tokens
            try uniswapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
                received,
                minOut,
                path,
                msg.sender,
                block.timestamp
            ) {
                emit TokenSwapped(msg.sender, tokenAddress, received, minOut);
            } catch {
                continue; // Skip if swap fails
            }
        }
    }

    receive() external payable {}
}

