// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IMDCred} from "../src/IMDCred.sol";

/// @notice Drives IMDCred with random sequences of transfers, approvals, transferFroms, burns and
/// permits from a pool of actors, and keeps ghost accounting of what every tracked address should
/// hold, what every (owner, spender) pair should be allowed, how much was burned and how many
/// permits each owner has consumed.
///
/// The handler itself deploys the token, so it stands in for the factory and starts with the whole
/// supply. Clamped handlers prepare inputs that reach the success path; unclamped handlers pass raw
/// inputs and assert that the token rejects exactly the inputs it should (and only those), so every
/// handler returns without reverting and `fail_on_revert` can stay on.
contract IMDCredHandler is Test {
    IMDCred public immutable token;

    uint256 public constant ACTOR_COUNT = 6;
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    address[] public actors;
    uint256[] private actorKeys;

    // Every address that has ever held a balance (actors, the deployer and arbitrary recipients).
    address[] public holders;
    mapping(address => bool) public isHolder;

    // Ghost accounting.
    mapping(address => uint256) public ghostReceived;
    mapping(address => uint256) public ghostSent;
    mapping(address => uint256) public ghostBurnedBy;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    mapping(address => uint256) public ghostNonce;
    uint256 public ghostBurned;

    // Call statistics, so the suite can tell whether the paths it claims to exercise were reached.
    uint256 public transfersOk;
    uint256 public transfersRejected;
    uint256 public transferFromsOk;
    uint256 public transferFromsRejected;
    uint256 public burnsOk;
    uint256 public burnsRejected;
    uint256 public permitsOk;
    uint256 public permitsRejected;

    // The last permit that went through, kept so a replay can be attempted later in the sequence.
    struct UsedPermit {
        address owner;
        address spender;
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
        bool exists;
    }

    UsedPermit private lastPermit;

    constructor() {
        token = new IMDCred();
        _track(address(this));
        ghostReceived[address(this)] = token.TOTAL_SUPPLY();

        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            uint256 key = uint256(keccak256(abi.encode("IMDCred actor", i)));
            // Keep the key inside the secp256k1 order so vm.addr and vm.sign accept it.
            key = bound(key, 1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140);
            actorKeys.push(key);
            address actor = vm.addr(key);
            actors.push(actor);
            _track(actor);
        }
    }

    // ---------------------------------------------------------------- views for the invariants

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /// @dev What the ghost accounting says `who` should hold.
    function ghostBalance(address who) public view returns (uint256) {
        return ghostReceived[who] - ghostSent[who] - ghostBurnedBy[who];
    }

    // ---------------------------------------------------------------- clamped handlers

    /// @notice The deployer (factory stand-in) hands part of the supply to an actor, as the launch does.
    function seed(uint256 toSeed, uint256 amount) external {
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(address(this)));
        _expectTransferOk(address(this), to, amount);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        _expectTransferOk(from, to, amount);
    }

    function transferAll(uint256 fromSeed, uint256 toSeed) external {
        address from = _actor(fromSeed);
        _expectTransferOk(from, _actor(toSeed), token.balanceOf(from));
    }

    function selfTransfer(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        _expectTransferOk(from, from, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        ghostAllowance[owner][spender] = amount;
    }

    function approveInfinite(uint256 ownerSeed, uint256 spenderSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        vm.prank(owner);
        token.approve(spender, type(uint256).max);
        ghostAllowance[owner][spender] = type(uint256).max;
    }

    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 cap = token.balanceOf(owner);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed < cap) cap = allowed;
        amount = bound(amount, 0, cap);
        _expectTransferFromOk(spender, owner, to, amount);
    }

    function burn(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        _expectBurnOk(from, amount);
    }

    function burnAll(uint256 fromSeed) external {
        address from = _actor(fromSeed);
        _expectBurnOk(from, token.balanceOf(from));
    }

    /// @notice The deployer burns from its own balance, the way bought-back tokens are destroyed.
    function deployerBurn(uint256 amount) external {
        amount = bound(amount, 0, token.balanceOf(address(this)));
        _expectBurnOk(address(this), amount);
    }

    function permit(uint256 ownerSeed, uint256 spenderSeed, uint256 relayerSeed, uint256 value, uint256 deadline)
        external
    {
        uint256 ownerIndex = bound(ownerSeed, 0, actors.length - 1);
        address owner = actors[ownerIndex];
        address spender = _actor(spenderSeed);
        deadline = bound(deadline, block.timestamp, type(uint256).max);
        uint256 nonce = token.nonces(owner);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(actorKeys[ownerIndex], _digest(owner, spender, value, nonce, deadline));

        vm.prank(_actor(relayerSeed));
        token.permit(owner, spender, value, deadline, v, r, s);

        ghostAllowance[owner][spender] = value;
        ghostNonce[owner] += 1;
        permitsOk += 1;
        lastPermit = UsedPermit(owner, spender, value, deadline, v, r, s, true);
        assertEq(token.allowance(owner, spender), value, "permit did not set the allowance");
    }

    function warp(uint256 by) external {
        by = bound(by, 0, 365 days);
        vm.warp(block.timestamp + by);
    }

    // ---------------------------------------------------------------- unclamped handlers

    /// @notice Raw transfer: any actor, any recipient, any amount. Must succeed exactly when the
    /// recipient is non-zero and the amount is within balance, and revert otherwise.
    function transferUnclamped(uint256 fromSeed, address to, uint256 amount) external {
        address from = _actor(fromSeed);
        uint256 held = token.balanceOf(from);
        if (to == address(0)) {
            vm.prank(from);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            token.transfer(to, amount);
            transfersRejected += 1;
        } else if (amount > held) {
            vm.prank(from);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount));
            token.transfer(to, amount);
            transfersRejected += 1;
        } else {
            _expectTransferOk(from, to, amount);
        }
        assertEq(token.balanceOf(from), ghostBalance(from), "rejected transfer changed the sender");
    }

    function transferFromUnclamped(uint256 spenderSeed, uint256 ownerSeed, address to, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 held = token.balanceOf(owner);
        if (amount > allowed) {
            vm.prank(spender);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
            );
            token.transferFrom(owner, to, amount);
            transferFromsRejected += 1;
        } else if (to == address(0)) {
            vm.prank(spender);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            token.transferFrom(owner, to, amount);
            transferFromsRejected += 1;
        } else if (amount > held) {
            vm.prank(spender);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount));
            token.transferFrom(owner, to, amount);
            transferFromsRejected += 1;
        } else {
            _expectTransferFromOk(spender, owner, to, amount);
        }
        assertEq(token.allowance(owner, spender), ghostAllowance[owner][spender], "a failed pull changed the allowance");
        assertEq(token.balanceOf(owner), ghostBalance(owner), "a failed pull changed the owner's balance");
    }

    function burnUnclamped(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        uint256 held = token.balanceOf(from);
        if (amount > held) {
            vm.prank(from);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount));
            token.burn(amount);
            burnsRejected += 1;
            assertEq(token.balanceOf(from), held, "a rejected burn changed the balance");
        } else {
            _expectBurnOk(from, amount);
        }
    }

    /// @notice Replays the most recent successful permit. It must be rejected and consume nothing.
    function permitReplay(uint256 relayerSeed) external {
        if (!lastPermit.exists) return;
        UsedPermit memory p = lastPermit;
        uint256 nonceBefore = token.nonces(p.owner);
        uint256 allowanceBefore = token.allowance(p.owner, p.spender);
        vm.prank(_actor(relayerSeed));
        vm.expectRevert();
        token.permit(p.owner, p.spender, p.value, p.deadline, p.v, p.r, p.s);
        permitsRejected += 1;
        assertEq(token.nonces(p.owner), nonceBefore, "a replayed permit consumed a nonce");
        assertEq(token.allowance(p.owner, p.spender), allowanceBefore, "a replayed permit changed the allowance");
    }

    /// @notice A permit whose deadline has already passed must be rejected without consuming the nonce.
    function permitExpired(uint256 ownerSeed, uint256 spenderSeed, uint256 value, uint256 age) external {
        if (block.timestamp == 0) return;
        uint256 ownerIndex = bound(ownerSeed, 0, actors.length - 1);
        address owner = actors[ownerIndex];
        address spender = _actor(spenderSeed);
        uint256 deadline = block.timestamp - bound(age, 1, block.timestamp);
        uint256 nonce = token.nonces(owner);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(actorKeys[ownerIndex], _digest(owner, spender, value, nonce, deadline));
        uint256 allowanceBefore = token.allowance(owner, spender);

        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(owner, spender, value, deadline, v, r, s);
        permitsRejected += 1;
        assertEq(token.nonces(owner), nonce, "an expired permit consumed a nonce");
        assertEq(token.allowance(owner, spender), allowanceBefore, "an expired permit changed the allowance");
    }

    /// @notice A permit signed by someone other than the owner must be rejected.
    function permitForged(uint256 ownerSeed, uint256 forgerSeed, uint256 spenderSeed, uint256 value) external {
        uint256 ownerIndex = bound(ownerSeed, 0, actors.length - 1);
        uint256 forgerIndex = bound(forgerSeed, 0, actors.length - 1);
        if (forgerIndex == ownerIndex) forgerIndex = (forgerIndex + 1) % actors.length;
        address owner = actors[ownerIndex];
        address spender = _actor(spenderSeed);
        uint256 nonce = token.nonces(owner);
        uint256 deadline = type(uint256).max;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(actorKeys[forgerIndex], _digest(owner, spender, value, nonce, deadline));
        uint256 allowanceBefore = token.allowance(owner, spender);

        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, actors[forgerIndex], owner));
        token.permit(owner, spender, value, deadline, v, r, s);
        permitsRejected += 1;
        assertEq(token.nonces(owner), nonce, "a forged permit consumed a nonce");
        assertEq(token.allowance(owner, spender), allowanceBefore, "a forged permit changed the allowance");
    }

    // ---------------------------------------------------------------- internals

    function _actor(uint256 pick) private view returns (address) {
        return actors[bound(pick, 0, actors.length - 1)];
    }

    function _track(address who) private {
        if (!isHolder[who]) {
            isHolder[who] = true;
            holders.push(who);
        }
    }

    function _expectTransferOk(address from, address to, uint256 amount) private {
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "transfer returned false");
        _recordMove(from, to, amount, fromBefore, toBefore);
        transfersOk += 1;
    }

    function _expectTransferFromOk(address spender, address owner, address to, uint256 amount) private {
        uint256 fromBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "transferFrom returned false");
        _recordMove(owner, to, amount, fromBefore, toBefore);
        if (ghostAllowance[owner][spender] != type(uint256).max) ghostAllowance[owner][spender] -= amount;
        transferFromsOk += 1;
    }

    function _recordMove(address from, address to, uint256 amount, uint256 fromBefore, uint256 toBefore) private {
        _track(to);
        ghostSent[from] += amount;
        ghostReceived[to] += amount;
        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self-transfer changed the balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "sender did not lose exactly the amount");
            assertEq(token.balanceOf(to), toBefore + amount, "receiver did not gain exactly the amount");
        }
    }

    function _expectBurnOk(address from, uint256 amount) private {
        uint256 before = token.balanceOf(from);
        uint256 supplyBefore = token.totalSupply();
        vm.prank(from);
        token.burn(amount);
        ghostBurnedBy[from] += amount;
        ghostBurned += amount;
        burnsOk += 1;
        assertEq(token.balanceOf(from), before - amount, "burn did not remove exactly the amount");
        assertEq(token.totalSupply(), supplyBefore - amount, "burn did not shrink the supply by the amount");
    }

    function _digest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        private
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }
}

/// @notice Properties IMDCred must keep after any sequence of calls the handler can make.
/// @dev `fail_on_revert` is on: every handler asserts the exact outcome it expects, so a revert
/// anywhere is a harness or contract defect, never noise.
contract IMDCredInvariantTest is StdInvariant, Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    IMDCredHandler handler;
    IMDCred token;
    bytes32 domainAtDeployment;

    function setUp() public {
        handler = new IMDCredHandler();
        token = handler.token();
        domainAtDeployment = token.DOMAIN_SEPARATOR();
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_supplyIsInitialMinusBurned() public view {
        assertEq(token.totalSupply(), SUPPLY - handler.ghostBurned(), "supply is not the mint minus the burns");
        assertLe(token.totalSupply(), SUPPLY, "supply grew past the mint");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_sumOfBalancesEqualsSupply() public view {
        uint256 n = handler.holderCount();
        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            sum += token.balanceOf(handler.holders(i));
        }
        assertEq(sum, token.totalSupply(), "tracked balances do not add up to the supply");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyHolderHasExactlyWhatItWasSent() public view {
        uint256 n = handler.holderCount();
        for (uint256 i = 0; i < n; i++) {
            address who = handler.holders(i);
            assertEq(
                token.balanceOf(who),
                handler.ghostBalance(who),
                "a balance drifted from received minus sent minus burned"
            );
            assertLe(token.balanceOf(who), SUPPLY, "a holder holds more than was ever minted");
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_allowancesMatchGhost() public view {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            address owner = handler.actors(i);
            for (uint256 j = 0; j < n; j++) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender), "allowance drifted");
            }
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_noncesCountSuccessfulPermitsOnly() public view {
        uint256 n = handler.actorCount();
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            address owner = handler.actors(i);
            assertEq(token.nonces(owner), handler.ghostNonce(owner), "nonce drifted from the permits that went through");
            total += token.nonces(owner);
        }
        assertEq(total, handler.permitsOk(), "nonces consumed differ from successful permits");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_zeroAddressNeverHoldsTokens() public view {
        assertEq(token.balanceOf(address(0)), 0);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_metadataAndDomainAreFixed() public view {
        assertEq(token.name(), "IMDCred");
        assertEq(token.symbol(), "IMDCRED");
        assertEq(uint256(token.decimals()), 18);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.DOMAIN_SEPARATOR(), domainAtDeployment, "the permit domain changed on a fixed chain");
    }

    /// @dev The handler's counters (transfersOk, burnsRejected, permitsOk, ...) say which paths a
    /// campaign reached. They are deliberately not asserted here: a replayed, shrunk failure is a
    /// one-call sequence and a count check on it would hide the real failure. Non-vacuity was
    /// grounded instead by running this harness against a mutant token that mints 1% of every
    /// transfer to the deployer; every invariant failed within the first run.
}
