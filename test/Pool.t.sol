// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "src/Pool.sol";
import "src/SwapRouter.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allow");
        allowance[from][msg.sender] = a - amount;
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract PoolTest is Test {
    MockERC20 t0;
    MockERC20 t1;
    Pool pool;
    SwapRouter router;

    function setUp() public {
        t0 = new MockERC20("T0", "T0", 18);
        t1 = new MockERC20("T1", "T1", 18);
        pool = new Pool(address(t0), address(t1), 3000, 1e18, 5e17, 2e18);
        router = new SwapRouter();
        t0.mint(address(this), 1_000_000 ether);
        t1.mint(address(this), 1_000_000 ether);
    }

    function test_add_liquidity_and_swap_exact_in() public {
        t0.approve(address(pool), type(uint256).max);
        t1.approve(address(pool), type(uint256).max);
        t0.transfer(address(pool), 1000 ether);
        t1.transfer(address(pool), 1000 ether);
        (uint256 tokenId, uint256 shares, , ) = pool.mintLiquidity(address(this));
        assertGt(shares, 0);
        t0.approve(address(router), 100 ether);
        (uint256 out, ) = router.swapExactIn(
            address(pool),
            address(t0),
            100 ether,
            0,
            address(this)
        );
        assertGt(out, 0);
    }

    function test_partial_fill_on_exact_in_due_to_reserve_limit() public {
        t0.approve(address(pool), type(uint256).max);
        t1.approve(address(pool), type(uint256).max);
        t0.transfer(address(pool), 1000 ether);
        t1.transfer(address(pool), 10 ether);
        pool.mintLiquidity(address(this));
        uint256 bal1Before = t1.balanceOf(address(this));
        t0.approve(address(router), 1000 ether);
        (uint256 out, uint256 inUsed) = router.swapExactIn(
            address(pool),
            address(t0),
            1000 ether,
            0,
            address(this)
        );
        assertGt(out, 0);
        assertLt(out, 10 ether);
        assertLt(inUsed, 1000 ether);
        assertEq(t1.balanceOf(address(this)) - bal1Before, out);
    }

    function test_exact_out_refund_unused_input() public {
        t0.approve(address(pool), type(uint256).max);
        t1.approve(address(pool), type(uint256).max);
        t0.transfer(address(pool), 1000 ether);
        t1.transfer(address(pool), 10 ether);
        pool.mintLiquidity(address(this));
        t0.mint(address(this), 200 ether);
        t0.approve(address(router), type(uint256).max);
        (uint256 inQuote, ) = router.quoteExactOut(address(pool), address(t0), 100 ether);
        uint256 bal0Before = t0.balanceOf(address(this));
        (uint256 inGross, uint256 outActual) = router.swapExactOut(
            address(pool),
            address(t0),
            100 ether,
            inQuote,
            address(this)
        );
        assertGt(outActual, 0);
        assertLe(outActual, 10 ether);
        uint256 spent = bal0Before - t0.balanceOf(address(this));
        assertEq(spent, inGross);
        assertLt(inGross, inQuote);
    }

    function test_fee_distribution_two_lps() public {
        address lp1 = address(0xA1);
        address lp2 = address(0xB1);
        t0.mint(lp1, 1000 ether);
        t1.mint(lp1, 1000 ether);
        t0.mint(lp2, 1000 ether);
        t1.mint(lp2, 1000 ether);
        vm.startPrank(lp1);
        t0.approve(address(pool), type(uint256).max);
        t1.approve(address(pool), type(uint256).max);
        t0.transfer(address(pool), 1000 ether);
        t1.transfer(address(pool), 1000 ether);
        (uint256 tokenId1, , , ) = pool.mintLiquidity(lp1);
        vm.stopPrank();
        vm.startPrank(lp2);
        t0.approve(address(pool), type(uint256).max);
        t1.approve(address(pool), type(uint256).max);
        t0.transfer(address(pool), 1000 ether);
        t1.transfer(address(pool), 1000 ether);
        (uint256 tokenId2, , , ) = pool.mintLiquidity(lp2);
        vm.stopPrank();
        t0.mint(address(this), 100 ether);
        t0.approve(address(router), type(uint256).max);
        router.swapExactIn(address(pool), address(t0), 100 ether, 0, address(this));
        uint256 b1 = t0.balanceOf(lp1);
        uint256 b2 = t0.balanceOf(lp2);
        vm.prank(lp1);
        pool.collectFees(tokenId1, lp1);
        vm.prank(lp2);
        pool.collectFees(tokenId2, lp2);
        assertGt(t0.balanceOf(lp1) - b1, 0);
        assertGt(t0.balanceOf(lp2) - b2, 0);
    }

    function test_no_liquidity_reverts_on_swap() public {
        t0.mint(address(this), 1 ether);
        t0.approve(address(router), type(uint256).max);
        vm.expectRevert(bytes("NO_LIQUIDITY"));
        router.swapExactIn(address(pool), address(t0), 1 ether, 0, address(this));
    }
}
