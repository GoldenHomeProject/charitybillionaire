// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAavePool} from "../../src/interfaces/IAavePool.sol";
import {IRandomProvider} from "../../src/interfaces/IRandomProvider.sol";

/// @notice 6-decimal mintable token, standing in for USDC and for the aToken.
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _decimals = d;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @notice Minimal Aave-like pool. Holds the asset, mints/burns an aToken 1:1 on
///         supply/withdraw, and exposes `accrueYield` to simulate interest: it mints
///         fresh asset into the pool AND fresh aToken to the holder, so the holder's
///         aToken balance rises above principal and the pool can honor the payout.
contract MockAavePool is IAavePool {
    MockERC20 public immutable asset;
    MockERC20 public immutable aToken;
    bool public failWithdraw; // test toggle: simulate Aave withdrawals paused/frozen

    constructor(MockERC20 _asset, MockERC20 _aToken) {
        asset = _asset;
        aToken = _aToken;
    }

    /// @dev Test helper: make every subsequent withdraw revert (Aave outage sim).
    function setFailWithdraw(bool _fail) external {
        failWithdraw = _fail;
    }

    function supply(address, uint256 amount, address onBehalfOf, uint16) external override {
        asset.transferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address, uint256 amount, address to) external override returns (uint256) {
        require(!failWithdraw, "AAVE_WITHDRAW_PAUSED");
        aToken.burn(msg.sender, amount);
        asset.transfer(to, amount);
        return amount;
    }

    /// @dev Test helper: simulate yield accruing to `holder`.
    function accrueYield(address holder, uint256 amount) external {
        asset.mint(address(this), amount);
        aToken.mint(holder, amount);
    }
}

/// @notice Stand-in for an Endaoment Org entity. On `donate`, it pulls `amount` of the
///         asset from the caller, skims a fee (bps) to `treasury`, and keeps the rest as
///         its grantable balance — mirroring how a real Org charges the protocol fee.
contract MockEndaomentOrg {
    MockERC20 public immutable asset;
    address public immutable treasury;
    uint16 public immutable feeBps;

    constructor(MockERC20 _asset, address _treasury, uint16 _feeBps) {
        asset = _asset;
        treasury = _treasury;
        feeBps = _feeBps;
    }

    function donate(uint256 amount) external {
        asset.transferFrom(msg.sender, address(this), amount);
        uint256 fee = (amount * feeBps) / 10_000;
        if (fee > 0) asset.transfer(treasury, fee);
    }
}

/// @notice Stand-in for Endaoment's OrgFundFactory. Deterministically maps each orgId to
///         a deployed MockEndaomentOrg (deployed lazily on first donate). `deployOrgAndDonate`
///         reverts if the Org already exists (matching the real factory), forcing the vault's
///         direct-donate fallback path.
contract MockEndaomentFactory {
    MockERC20 public immutable asset;
    address public immutable treasury;
    uint16 public immutable feeBps;
    mapping(bytes32 => address) public orgOf;

    constructor(MockERC20 _asset, address _treasury, uint16 _feeBps) {
        asset = _asset;
        treasury = _treasury;
        feeBps = _feeBps;
    }

    function deployOrgAndDonate(bytes32 orgId, uint256 amount) external returns (address) {
        require(orgOf[orgId] == address(0), "org exists");
        MockEndaomentOrg org = new MockEndaomentOrg(asset, treasury, feeBps);
        orgOf[orgId] = address(org);
        uint256 fee = (amount * feeBps) / 10_000;
        if (fee > 0) asset.transferFrom(msg.sender, treasury, fee);
        asset.transferFrom(msg.sender, address(org), amount - fee);
        return address(org);
    }

    function computeOrgAddress(bytes32 orgId) external view returns (address) {
        return orgOf[orgId];
    }
}

/// @notice An Endaoment factory whose calls always revert, to exercise the vault's
///         try/catch fallback (route fails -> direct charity address / fold to company).
contract MockRevertingEndaomentFactory {
    function deployOrgAndDonate(bytes32, uint256) external pure returns (address) {
        revert("endaoment down");
    }

    function computeOrgAddress(bytes32) external pure returns (address) {
        revert("endaoment down");
    }
}

interface IVRFConsumer {
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

/// @notice Stand-in for the Chainlink VRF coordinator. Records the consumer on
///         request; `fulfill` calls back FROM this contract's address so the
///         consumer's `msg.sender == randomProvider` check passes.
contract MockRandomProvider is IRandomProvider {
    uint256 public nextId = 1;
    address public lastConsumer;
    uint256 public lastRequestId;

    function requestRandomWords(address consumer) external override returns (uint256 requestId) {
        requestId = nextId++;
        lastConsumer = consumer;
        lastRequestId = requestId;
    }

    function fulfill(uint256 requestId, uint256 randomWord) external {
        uint256[] memory words = new uint256[](1);
        words[0] = randomWord;
        IVRFConsumer(lastConsumer).fulfillRandomWords(requestId, words);
    }
}
