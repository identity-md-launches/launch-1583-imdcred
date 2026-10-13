// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IMDCred} from "../src/IMDCred.sol";
import {DeployIMDCred} from "../script/DeployIMDCred.s.sol";

/// @notice Stands in for the launch factory: deploys the token through CREATE2 from its own
/// address and holds the supply, the way ProjectFactory does on Robinhood Chain.
contract FactoryProbe {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
    }

    function move(IERC20 token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract IMDCredTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant SWARM_BPS = 1_000;
    uint256 constant POOL_BPS = 9_000;
    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    FactoryProbe factory;
    IMDCred token;

    address constant DISTRIBUTOR = address(0xD157);
    address constant CLAIMANT = address(0xC1A1);
    address constant POOL_MANAGER = address(0x900C);
    address constant REQUESTER = address(0x5E90);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    uint256 constant OWNER_KEY = 0xA11CE;
    address owner;

    function setUp() public {
        factory = new FactoryProbe();
        token = IMDCred(factory.deploy(type(IMDCred).creationCode, bytes32(uint256(1))));
        owner = vm.addr(OWNER_KEY);
    }

    // ---------------------------------------------------------------- metadata and supply

    function test_metadata() public view {
        assertEq(token.name(), "IMDCred");
        assertEq(token.symbol(), "IMDCRED");
        assertEq(uint256(token.decimals()), 18);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY, "the deployer does not hold the whole supply");
        assertEq(token.balanceOf(address(this)), 0, "the test (tx origin side) received tokens");
        assertEq(token.balanceOf(tx.origin), 0, "tx.origin received tokens");
    }

    function test_constructorTakesNoArguments() public {
        // Deploying the bare creation code from any address mints to exactly that address.
        FactoryProbe other = new FactoryProbe();
        IMDCred second = IMDCred(other.deploy(type(IMDCred).creationCode, bytes32(uint256(2))));
        assertEq(second.totalSupply(), SUPPLY);
        assertEq(second.balanceOf(address(other)), SUPPLY);
        assertEq(second.balanceOf(address(factory)), 0);
    }

    function test_deployScriptMintsToTheCaller() public {
        DeployIMDCred script = new DeployIMDCred();
        IMDCred deployed = script.deploy();
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(script)), SUPPLY);
    }

    function test_mintedEventIsEmittedOnce() public {
        FactoryProbe other = new FactoryProbe();
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), address(other), SUPPLY);
        other.deploy(type(IMDCred).creationCode, bytes32(uint256(3)));
    }

    // ---------------------------------------------------------------- launch flows arrive whole

    function test_launchFlowsArriveWhole() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        uint256 pool = (SUPPLY * POOL_BPS) / 10_000;
        uint256 remainder = SUPPLY - swarm - pool;

        assertTrue(factory.move(token, DISTRIBUTOR, swarm));
        assertEq(token.balanceOf(DISTRIBUTOR), swarm, "swarm share arrived short");

        assertTrue(factory.move(token, POOL_MANAGER, pool));
        assertEq(token.balanceOf(POOL_MANAGER), pool, "pool seed arrived short");

        assertTrue(factory.move(token, REQUESTER, remainder));
        assertEq(token.balanceOf(REQUESTER), remainder, "remainder arrived short");
        assertEq(token.balanceOf(address(factory)), 0, "the factory kept something back");

        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT, swarm));
        assertEq(token.balanceOf(CLAIMANT), swarm, "claim arrived short");
        assertEq(token.balanceOf(DISTRIBUTOR), 0);

        // A trader buys from and sells back into the pool manager, both legs whole.
        vm.prank(POOL_MANAGER);
        assertTrue(token.transfer(ALICE, 1 ether));
        assertEq(token.balanceOf(ALICE), 1 ether);
        vm.prank(ALICE);
        assertTrue(token.transfer(POOL_MANAGER, 1 ether));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(POOL_MANAGER), pool);

        assertEq(token.totalSupply(), SUPPLY, "launch flows changed the supply");
    }

    // ---------------------------------------------------------------- transfers

    function test_transferMovesExactAmount() public {
        factory.move(token, ALICE, 100 ether);
        vm.prank(ALICE);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(ALICE, BOB, 40 ether);
        assertTrue(token.transfer(BOB, 40 ether));
        assertEq(token.balanceOf(ALICE), 60 ether);
        assertEq(token.balanceOf(BOB), 40 ether);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        factory.move(token, ALICE, 10 ether);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 10 ether, 11 ether)
        );
        token.transfer(BOB, 11 ether);
    }

    function test_transferToZeroAddressReverts() public {
        factory.move(token, ALICE, 10 ether);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);
    }

    function test_approveAndTransferFrom() public {
        factory.move(token, ALICE, 100 ether);
        vm.prank(ALICE);
        assertTrue(token.approve(BOB, 30 ether));
        assertEq(token.allowance(ALICE, BOB), 30 ether);

        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, CLAIMANT, 20 ether));
        assertEq(token.balanceOf(CLAIMANT), 20 ether);
        assertEq(token.balanceOf(ALICE), 80 ether);
        assertEq(token.allowance(ALICE, BOB), 10 ether);
    }

    function test_transferFromRevertsOnInsufficientAllowance() public {
        factory.move(token, ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(BOB, 5 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 5 ether, 6 ether));
        token.transferFrom(ALICE, CLAIMANT, 6 ether);
    }

    function test_transferFromWithoutAllowanceReverts() public {
        factory.move(token, ALICE, 100 ether);
        // Even the deployer cannot pull a holder's balance without an allowance.
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, 1)
        );
        token.transferFrom(ALICE, address(factory), 1);
        assertEq(token.balanceOf(ALICE), 100 ether);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        factory.move(token, ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        token.transferFrom(ALICE, CLAIMANT, 50 ether);
        assertEq(token.allowance(ALICE, BOB), type(uint256).max);
    }

    function testFuzz_transfersConserveSupply(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, a);
        c = bound(c, 0, b);
        factory.move(token, ALICE, a);
        vm.prank(ALICE);
        token.transfer(BOB, b);
        vm.prank(BOB);
        token.transfer(CLAIMANT, c);
        assertEq(
            token.balanceOf(address(factory)) + token.balanceOf(ALICE) + token.balanceOf(BOB)
                + token.balanceOf(CLAIMANT),
            SUPPLY
        );
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(ALICE), a - b);
        assertEq(token.balanceOf(BOB), b - c);
        assertEq(token.balanceOf(CLAIMANT), c);
    }

    // ---------------------------------------------------------------- burn

    function test_burnReducesBalanceAndSupply() public {
        factory.move(token, ALICE, 100 ether);
        vm.prank(ALICE);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(ALICE, address(0), 30 ether);
        token.burn(30 ether);
        assertEq(token.balanceOf(ALICE), 70 ether);
        assertEq(token.totalSupply(), SUPPLY - 30 ether);
    }

    function test_burnMoreThanBalanceReverts() public {
        factory.move(token, ALICE, 10 ether);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 10 ether, 11 ether)
        );
        token.burn(11 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_burnZeroIsANoOp() public {
        vm.prank(BOB);
        token.burn(0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_burnOnlyShrinksSupply(uint256 held, uint256 burned) public {
        held = bound(held, 0, SUPPLY);
        burned = bound(burned, 0, held);
        factory.move(token, ALICE, held);
        vm.prank(ALICE);
        token.burn(burned);
        assertEq(token.totalSupply(), SUPPLY - burned);
        assertEq(token.balanceOf(ALICE), held - burned);
    }

    // ---------------------------------------------------------------- no privileged hand

    function test_noMintOrAdminSelectorExists() public {
        address attacker = address(0xBEEF);
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "owner()",
            "burnFrom(address,uint256)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(address(factory));
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        factory.move(token, ALICE, SUPPLY / 1_000);
        uint256 held = token.balanceOf(ALICE);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, true);
            vm.prank(address(factory));
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.balanceOf(ALICE), held);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, held / 2));
        assertEq(token.balanceOf(BOB), held / 2);
    }

    function test_runtimeCodeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    function test_rejectsEther() public {
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "the token accepted ether");
    }

    // ---------------------------------------------------------------- permit (EIP-2612)

    function _permitDigest(address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function test_permitSetsAllowanceAndSpendsNonce() public {
        factory.move(token, owner, 100 ether);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _permitDigest(BOB, 25 ether, 0, deadline));

        vm.prank(BOB);
        token.permit(owner, BOB, 25 ether, deadline, v, r, s);
        assertEq(token.allowance(owner, BOB), 25 ether);
        assertEq(token.nonces(owner), 1);

        vm.prank(BOB);
        token.transferFrom(owner, CLAIMANT, 25 ether);
        assertEq(token.balanceOf(CLAIMANT), 25 ether);
    }

    function test_permitRejectsReplay() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _permitDigest(BOB, 25 ether, 0, deadline));
        token.permit(owner, BOB, 25 ether, deadline, v, r, s);
        vm.expectRevert();
        token.permit(owner, BOB, 25 ether, deadline, v, r, s);
    }

    function test_permitRejectsExpiredDeadline() public {
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _permitDigest(BOB, 25 ether, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(owner, BOB, 25 ether, deadline, v, r, s);
    }

    function test_permitRejectsWrongSigner() public {
        uint256 deadline = block.timestamp + 1 hours;
        uint256 otherKey = 0xB0B;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherKey, _permitDigest(BOB, 25 ether, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, vm.addr(otherKey), owner));
        token.permit(owner, BOB, 25 ether, deadline, v, r, s);
        assertEq(token.allowance(owner, BOB), 0);
    }

    function test_permitRejectsTamperedValue() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _permitDigest(BOB, 25 ether, 0, deadline));
        vm.expectRevert();
        token.permit(owner, BOB, 26 ether, deadline, v, r, s);
        assertEq(token.allowance(owner, BOB), 0);
    }
}
