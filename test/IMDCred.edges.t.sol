// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {IMDCred} from "../src/IMDCred.sol";

/// @notice Edge inputs the main suite does not reach: zero, one wei, the whole supply, the same
/// call twice, self as counterparty, signature malleability and chain-bound permits. Deployed from
/// a dedicated deployer address so the test contract itself is an ordinary stranger to the token.
contract IMDCredEdgesTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    IMDCred token;

    address constant DEPLOYER = address(0xDE91);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA201);

    uint256 constant OWNER_KEY = 0x0A11CE;
    address owner;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new IMDCred();
        owner = vm.addr(OWNER_KEY);
    }

    function _give(address to, uint256 amount) internal {
        vm.prank(DEPLOYER);
        token.transfer(to, amount);
    }

    function _digest(address owner_, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner_, spender, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    // ---------------------------------------------------------------- supply edges

    function test_supplyConstantIsExactlyOneBillionAtEighteenDecimals() public view {
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000_000_000_000_000_000_000);
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 * 10 ** uint256(token.decimals()));
    }

    function test_balanceOfZeroAddressIsZero() public view {
        assertEq(token.balanceOf(address(0)), 0);
    }

    function test_deployerCanMoveTheWholeSupplyInOneTransfer() public {
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(ALICE, SUPPLY));
        assertEq(token.balanceOf(ALICE), SUPPLY);
        assertEq(token.balanceOf(DEPLOYER), 0);
        // And one wei more than it has is refused.
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, DEPLOYER, 0, 1));
        token.transfer(ALICE, 1);
    }

    function test_wholeSupplyCanBeBurnedAndNothingWorksAfter() public {
        vm.prank(DEPLOYER);
        token.burn(SUPPLY);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(DEPLOYER), 0);
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, DEPLOYER, 0, 1));
        token.transfer(ALICE, 1);
        // The supply cannot come back: there is no mint, and a zero burn keeps it at zero.
        vm.prank(DEPLOYER);
        token.burn(0);
        assertEq(token.totalSupply(), 0);
    }

    function test_burnFromAnEmptyAccountRevertsForOneWei() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        token.burn(1);
    }

    function test_burnOfMaxUintReverts() public {
        _give(ALICE, 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 1 ether, type(uint256).max)
        );
        token.burn(type(uint256).max);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_burnDoesNotTouchAllowances() public {
        _give(ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 7 ether);
        vm.prank(ALICE);
        token.burn(10 ether);
        assertEq(token.allowance(ALICE, BOB), 7 ether, "burn changed an allowance");
        // The allowance is now larger than the balance; a pull fails on balance, not allowance.
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        token.transferFrom(ALICE, BOB, 1);
    }

    function test_burnTwiceSumsAndStopsAtBalance() public {
        _give(ALICE, 3);
        vm.prank(ALICE);
        token.burn(1);
        vm.prank(ALICE);
        token.burn(2);
        assertEq(token.totalSupply(), SUPPLY - 3);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        token.burn(1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_burnsFromSeveralHoldersSumExactly(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, SUPPLY / 3);
        b = bound(b, 0, SUPPLY / 3);
        c = bound(c, 0, SUPPLY / 3);
        _give(ALICE, a);
        _give(BOB, b);
        _give(CAROL, c);
        vm.prank(ALICE);
        token.burn(a);
        vm.prank(BOB);
        token.burn(b);
        vm.prank(CAROL);
        token.burn(c);
        assertEq(token.totalSupply(), SUPPLY - a - b - c);
        assertEq(
            token.balanceOf(DEPLOYER), token.totalSupply(), "the deployer's remainder is not the whole supply left"
        );
    }

    // ---------------------------------------------------------------- transfer edges

    function test_transferOfZeroSucceedsAndEmits() public {
        vm.prank(ALICE); // ALICE holds nothing
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(ALICE, BOB, 0);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_selfTransferKeepsBalance() public {
        _give(ALICE, 5 ether);
        vm.prank(ALICE);
        assertTrue(token.transfer(ALICE, 5 ether));
        assertEq(token.balanceOf(ALICE), 5 ether);
        assertEq(token.totalSupply(), SUPPLY);
        // Even a self-transfer cannot exceed the balance.
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 5 ether, 5 ether + 1)
        );
        token.transfer(ALICE, 5 ether + 1);
    }

    function test_transferOfOneWeiMovesOneWei() public {
        _give(ALICE, 1);
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 1);
    }

    function test_transferOfMaxUintRevertsWithoutMovingAnything() public {
        _give(ALICE, 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 1 ether, type(uint256).max)
        );
        token.transfer(BOB, type(uint256).max);
        assertEq(token.balanceOf(ALICE), 1 ether);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_transferToTheTokenItselfIsAllowedAndStuck() public {
        // Nothing stops a holder sending to the token contract, and nothing can get it back out:
        // the token has no owner and no rescue path. A holder who does this burns value in effect.
        _give(ALICE, 2 ether);
        vm.prank(ALICE);
        token.transfer(address(token), 2 ether);
        assertEq(token.balanceOf(address(token)), 2 ether);
        assertEq(token.totalSupply(), SUPPLY, "stuck tokens still count toward the supply");
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, DEPLOYER, 0, 2 ether));
        token.transferFrom(address(token), DEPLOYER, 2 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferAboveBalanceAlwaysReverts(uint256 held, uint256 excess) public {
        held = bound(held, 0, SUPPLY);
        excess = bound(excess, 1, type(uint256).max - held);
        _give(ALICE, held);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, held, held + excess)
        );
        token.transfer(BOB, held + excess);
        assertEq(token.balanceOf(ALICE), held);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferRoundTripRestoresBalances(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, held);
        _give(ALICE, held);
        vm.prank(ALICE);
        token.transfer(BOB, amount);
        vm.prank(BOB);
        token.transfer(ALICE, amount);
        assertEq(token.balanceOf(ALICE), held);
        assertEq(token.balanceOf(BOB), 0);
    }

    // ---------------------------------------------------------------- approval edges

    function test_approveToZeroSpenderReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_approveOverwritesRatherThanAdds() public {
        vm.prank(ALICE);
        token.approve(BOB, 5 ether);
        vm.prank(ALICE);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(ALICE, BOB, 2 ether);
        token.approve(BOB, 2 ether);
        assertEq(token.allowance(ALICE, BOB), 2 ether);
        vm.prank(ALICE);
        token.approve(BOB, 0);
        assertEq(token.allowance(ALICE, BOB), 0);
    }

    function test_allowanceMayExceedBalanceButPullIsCappedByBalance() public {
        _give(ALICE, 1 ether);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 1 ether, 1 ether + 1)
        );
        token.transferFrom(ALICE, BOB, 1 ether + 1);
        vm.prank(BOB);
        token.transferFrom(ALICE, BOB, 1 ether);
        assertEq(token.balanceOf(BOB), 1 ether);
    }

    function test_transferFromBySelfStillNeedsAllowance() public {
        _give(ALICE, 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        token.transferFrom(ALICE, BOB, 1);
        vm.prank(ALICE);
        token.approve(ALICE, 1);
        vm.prank(ALICE);
        token.transferFrom(ALICE, BOB, 1);
        assertEq(token.balanceOf(BOB), 1);
        assertEq(token.allowance(ALICE, ALICE), 0);
    }

    function test_transferFromToZeroRevertsEvenWithAllowance() public {
        _give(ALICE, 1 ether);
        vm.prank(ALICE);
        token.approve(BOB, 1 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(ALICE, address(0), 1 ether);
        assertEq(token.allowance(ALICE, BOB), 1 ether, "a failed pull spent allowance");
    }

    function test_transferFromOfZeroSpendsNoAllowance() public {
        vm.prank(ALICE);
        token.approve(BOB, 3);
        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, CAROL, 0));
        assertEq(token.allowance(ALICE, BOB), 3);
    }

    function test_allowanceIsExhaustedExactlyThenRefused() public {
        _give(ALICE, 10);
        vm.prank(ALICE);
        token.approve(BOB, 10);
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, 10);
        assertEq(token.allowance(ALICE, BOB), 0);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(ALICE, CAROL, 1);
    }

    function test_allowanceSurvivesAnOrdinaryTransfer() public {
        _give(ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 4 ether);
        vm.prank(ALICE);
        token.transfer(CAROL, 10 ether);
        assertEq(token.allowance(ALICE, BOB), 4 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_pullsDecrementAllowanceExactly(uint256 allowance, uint256 first, uint256 second) public {
        allowance = bound(allowance, 0, type(uint256).max - 1); // not the infinite sentinel
        first = bound(first, 0, allowance);
        second = bound(second, 0, allowance - first);
        _give(ALICE, SUPPLY);
        vm.prank(ALICE);
        token.approve(BOB, allowance);
        uint256 firstMove = first > SUPPLY ? SUPPLY : first;
        uint256 secondMove = second > SUPPLY - firstMove ? SUPPLY - firstMove : second;
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, firstMove);
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, secondMove);
        assertEq(token.allowance(ALICE, BOB), allowance - firstMove - secondMove);
        assertEq(token.balanceOf(CAROL), firstMove + secondMove);
    }

    // ---------------------------------------------------------------- permit edges

    function test_permitAtExactDeadlineIsAccepted() public {
        uint256 deadline = vm.getBlockTimestamp();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _digest(owner, BOB, 1, 0, deadline));
        token.permit(owner, BOB, 1, deadline, v, r, s);
        assertEq(token.allowance(owner, BOB), 1);
        // One second later the same deadline is expired for a fresh signature.
        vm.warp(deadline + 1);
        (v, r, s) = vm.sign(OWNER_KEY, _digest(owner, BOB, 2, 1, deadline));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(owner, BOB, 2, deadline, v, r, s);
        assertEq(token.nonces(owner), 1, "an expired permit consumed a nonce");
    }

    function test_permitWithMaxDeadlineAndZeroValue() public {
        vm.prank(owner);
        token.approve(BOB, 9);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _digest(owner, BOB, 0, 0, type(uint256).max));
        token.permit(owner, BOB, 0, type(uint256).max, v, r, s);
        assertEq(token.allowance(owner, BOB), 0, "a zero-value permit should clear the allowance");
        assertEq(token.nonces(owner), 1);
    }

    function test_permitForZeroSpenderReverts() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _digest(owner, address(0), 1, 0, type(uint256).max));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.permit(owner, address(0), 1, type(uint256).max, v, r, s);
    }

    function test_permitRejectsHighSMalleatedSignature() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _digest(owner, BOB, 1, 0, type(uint256).max));
        bytes32 sHigh = bytes32(SECP256K1_N - uint256(s));
        uint8 vFlipped = v == 27 ? 28 : 27;
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, sHigh));
        token.permit(owner, BOB, 1, type(uint256).max, vFlipped, r, sHigh);
        assertEq(token.allowance(owner, BOB), 0);
        assertEq(token.nonces(owner), 0);
    }

    function test_permitRejectsGarbageSignature() public {
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(owner, BOB, 1, type(uint256).max, 27, bytes32(0), bytes32(0));
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(owner, BOB, 1, type(uint256).max, 0, bytes32(uint256(1)), bytes32(uint256(1)));
        assertEq(token.nonces(owner), 0);
    }

    function test_permitRejectsWrongSpenderAndWrongOwner() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _digest(owner, BOB, 1, 0, type(uint256).max));
        // Submitted for a different spender: the recovered signer differs from the owner.
        vm.expectRevert();
        token.permit(owner, CAROL, 1, type(uint256).max, v, r, s);
        // Submitted naming a different owner: the recovered signer is not that owner either.
        vm.expectRevert();
        token.permit(ALICE, BOB, 1, type(uint256).max, v, r, s);
        assertEq(token.allowance(owner, BOB), 0);
        assertEq(token.allowance(owner, CAROL), 0);
        assertEq(token.allowance(ALICE, BOB), 0);
    }

    function test_permitIsBoundToTheChain() public {
        bytes32 domainHere = token.DOMAIN_SEPARATOR();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _digest(owner, BOB, 1, 0, type(uint256).max));
        vm.chainId(block.chainid + 1);
        assertTrue(token.DOMAIN_SEPARATOR() != domainHere, "domain separator ignores the chain id");
        vm.expectRevert();
        token.permit(owner, BOB, 1, type(uint256).max, v, r, s);
        assertEq(token.nonces(owner), 0);
        // On the new chain a fresh signature over the new domain works.
        (v, r, s) = vm.sign(OWNER_KEY, _digest(owner, BOB, 1, 0, type(uint256).max));
        token.permit(owner, BOB, 1, type(uint256).max, v, r, s);
        assertEq(token.allowance(owner, BOB), 1);
    }

    function test_permitNoncesAreIndependentPerOwner() public {
        uint256 otherKey = 0x0B0B;
        address other = vm.addr(otherKey);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _digest(owner, BOB, 1, 0, type(uint256).max));
        token.permit(owner, BOB, 1, type(uint256).max, v, r, s);
        assertEq(token.nonces(owner), 1);
        assertEq(token.nonces(other), 0);
        (v, r, s) = vm.sign(otherKey, _digest(other, BOB, 2, 0, type(uint256).max));
        token.permit(other, BOB, 2, type(uint256).max, v, r, s);
        assertEq(token.nonces(other), 1);
        assertEq(token.nonces(owner), 1);
    }

    function test_permitSignedForFutureNonceIsRejectedUntilItsTurn() public {
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(OWNER_KEY, _digest(owner, BOB, 1, 1, type(uint256).max));
        vm.expectRevert();
        token.permit(owner, BOB, 1, type(uint256).max, v1, r1, s1);
        (uint8 v0, bytes32 r0, bytes32 s0) = vm.sign(OWNER_KEY, _digest(owner, BOB, 5, 0, type(uint256).max));
        token.permit(owner, BOB, 5, type(uint256).max, v0, r0, s0);
        token.permit(owner, BOB, 1, type(uint256).max, v1, r1, s1);
        assertEq(token.allowance(owner, BOB), 1);
        assertEq(token.nonces(owner), 2);
    }

    function test_permitMovesNoTokensAndApproveOverridesIt() public {
        _give(owner, 10 ether);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _digest(owner, BOB, 10 ether, 0, type(uint256).max));
        token.permit(owner, BOB, 10 ether, type(uint256).max, v, r, s);
        assertEq(token.balanceOf(owner), 10 ether, "permit moved tokens");
        assertEq(token.balanceOf(BOB), 0);
        vm.prank(owner);
        token.approve(BOB, 0);
        assertEq(token.allowance(owner, BOB), 0, "approve did not override the permit");
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(owner, BOB, 1);
    }

    function test_eip712DomainMatchesSeparator() public view {
        (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifying,,) =
            IERC5267(address(token)).eip712Domain();
        assertEq(fields, bytes1(0x0f));
        assertEq(name, "IMDCred");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(token));
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifying
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected);
    }

    function test_twoDeploymentsHaveDistinctDomains() public {
        vm.prank(DEPLOYER);
        IMDCred second = new IMDCred();
        assertTrue(second.DOMAIN_SEPARATOR() != token.DOMAIN_SEPARATOR(), "a permit for one token replays on the other");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _digest(owner, BOB, 1, 0, type(uint256).max));
        vm.expectRevert();
        second.permit(owner, BOB, 1, type(uint256).max, v, r, s);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_permitFromAnyKeyThenPullExactly(uint256 key, uint256 value, uint256 deadline) public {
        key = bound(key, 1, SECP256K1_N - 1);
        value = bound(value, 0, SUPPLY);
        deadline = bound(deadline, block.timestamp, type(uint256).max);
        address signer = vm.addr(key);
        vm.assume(signer != DEPLOYER);
        _give(signer, value);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(signer, BOB, value, 0, deadline));
        vm.prank(CAROL); // anyone may relay a permit
        token.permit(signer, BOB, value, deadline, v, r, s);
        assertEq(token.allowance(signer, BOB), value);
        assertEq(token.nonces(signer), 1);
        vm.prank(BOB);
        token.transferFrom(signer, CAROL, value);
        assertEq(token.balanceOf(CAROL), value);
        assertEq(token.balanceOf(signer), 0);
        assertEq(token.allowance(signer, BOB), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_permitWithTamperedDeadlineIsRejected(uint256 deadline, uint256 shift) public {
        deadline = bound(deadline, block.timestamp, type(uint256).max - 1);
        shift = bound(shift, 1, type(uint256).max - deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _digest(owner, BOB, 1, 0, deadline));
        vm.expectRevert();
        token.permit(owner, BOB, 1, deadline + shift, v, r, s);
        assertEq(token.nonces(owner), 0);
    }

    // ---------------------------------------------------------------- unknown calls

    function test_unknownSelectorAndEmptyCalldataRevert() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("rescue(address,uint256)", ALICE, 1));
        assertFalse(ok);
        (ok,) = address(token).call("");
        assertFalse(ok, "the token has a fallback");
        (ok,) = address(token).call(hex"deadbeef");
        assertFalse(ok);
    }

    function test_strangerCannotPullFromTheDeployer() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        token.transferFrom(DEPLOYER, ALICE, 1);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
    }
}
