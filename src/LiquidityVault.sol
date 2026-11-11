// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface ILiquidityAsset {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Custody for balanced asset pairs valued at a fixed one-to-one rate.
contract PositionManager {
    struct Position { address owner; uint256 liquidity; }
    ILiquidityAsset public immutable ASSET_A;
    ILiquidityAsset public immutable ASSET_B;
    uint256 public nextId;
    mapping(uint256 => Position) public positions;
    event Increased(uint256 indexed tokenId, uint256 liquidity);
    event Decreased(uint256 indexed tokenId, uint256 liquidity);

    constructor(address assetA, address assetB) {
        require(assetA != address(0) && assetB != address(0) && assetA != assetB, "assets");
        ASSET_A = ILiquidityAsset(assetA);
        ASSET_B = ILiquidityAsset(assetB);
    }

    function mint() external returns (uint256 tokenId) {
        tokenId = ++nextId;
        positions[tokenId].owner = msg.sender;
    }

    function increaseLiquidity(uint256 tokenId, uint256 amountA, uint256 amountB)
        external returns (uint256 liquidity, uint256 usedA, uint256 usedB)
    {
        require(positions[tokenId].owner != address(0), "position");
        liquidity = amountA < amountB ? amountA : amountB;
        require(liquidity > 0, "amount");
        require(ASSET_A.transferFrom(msg.sender, address(this), liquidity), "asset A");
        require(ASSET_B.transferFrom(msg.sender, address(this), liquidity), "asset B");
        positions[tokenId].liquidity += liquidity;
        emit Increased(tokenId, liquidity);
        return (liquidity, liquidity, liquidity);
    }

    function decreaseLiquidity(uint256 tokenId, uint256 liquidity, address receiver)
        external returns (uint256 amountA, uint256 amountB)
    {
        Position storage position = positions[tokenId];
        require(msg.sender == position.owner && receiver != address(0), "owner");
        position.liquidity -= liquidity;
        require(ASSET_A.transfer(receiver, liquidity), "asset A");
        require(ASSET_B.transfer(receiver, liquidity), "asset B");
        emit Decreased(tokenId, liquidity);
        return (liquidity, liquidity);
    }
}

/// @notice Owns a managed position and routes allocations for one vault.
contract PortfolioAdapter {
    PositionManager public immutable POSITION_MANAGER;
    ILiquidityAsset public immutable ASSET_A;
    ILiquidityAsset public immutable ASSET_B;
    address public immutable vault;
    uint256 public immutable tokenId;

    constructor(PositionManager manager) {
        vault = msg.sender;
        POSITION_MANAGER = manager;
        ASSET_A = manager.ASSET_A();
        ASSET_B = manager.ASSET_B();
        tokenId = manager.mint();
        require(ASSET_A.approve(address(manager), type(uint256).max), "approval A");
        require(ASSET_B.approve(address(manager), type(uint256).max), "approval B");
    }

    modifier onlyVault() {
        require(msg.sender == vault, "vault");
        _;
    }

    function totalLiquidity() public view returns (uint256 liquidity) {
        (, liquidity) = POSITION_MANAGER.positions(tokenId);
    }

    function positionAmounts() public view returns (uint256 amountA, uint256 amountB) {
        uint256 liquidity = totalLiquidity();
        return (liquidity, liquidity);
    }

    function amountsForLiquidity(uint256 liquidity) external pure returns (uint256, uint256) {
        return (liquidity, liquidity);
    }

    function addLiquidity(uint256 amountA, uint256 amountB, uint256 minA, uint256 minB)
        external onlyVault returns (uint256 liquidity, uint256 usedA, uint256 usedB)
    {
        (liquidity, usedA, usedB) = POSITION_MANAGER.increaseLiquidity(tokenId, amountA, amountB);
        require(usedA >= minA && usedB >= minB, "minimum amounts");
        if (amountA > usedA) require(ASSET_A.transfer(vault, amountA - usedA), "refund A");
        if (amountB > usedB) require(ASSET_B.transfer(vault, amountB - usedB), "refund B");
    }

    function removeLiquidity(uint256 shares, uint256 supply, uint256 minA, uint256 minB, address receiver)
        external onlyVault returns (uint256 amountA, uint256 amountB)
    {
        uint256 liquidity = totalLiquidity() * shares / supply;
        require(liquidity >= minA && liquidity >= minB, "minimum amounts");
        return POSITION_MANAGER.decreaseLiquidity(tokenId, liquidity, receiver);
    }
}

/// @notice Issues portfolio shares against the value of an externally managed position.
contract LiquidityVault {
    error ZeroShares();
    ILiquidityAsset public immutable ASSET_A;
    ILiquidityAsset public immutable ASSET_B;
    PortfolioAdapter public immutable ADAPTER;
    uint256 public constant INITIAL_SCALE = 1e6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    uint256 private entered = 1;
    event Deposit(address indexed account, uint256 amountA, uint256 amountB, uint256 shares);
    event Withdraw(address indexed account, address indexed receiver, uint256 shares, uint256 amountA, uint256 amountB);

    constructor(PositionManager manager) {
        ASSET_A = manager.ASSET_A();
        ASSET_B = manager.ASSET_B();
        ADAPTER = new PortfolioAdapter(manager);
    }

    modifier nonReentrant() {
        require(entered == 1, "reentrancy");
        entered = 2;
        _;
        entered = 1;
    }

    function deposit(uint256 amountA, uint256 amountB, uint256 minA, uint256 minB)
        external nonReentrant returns (uint256 shares, uint256 usedA, uint256 usedB)
    {
        require(amountA > 0 && amountB > 0, "amounts");
        require(ASSET_A.transferFrom(msg.sender, address(this), amountA), "asset A");
        require(ASSET_B.transferFrom(msg.sender, address(this), amountB), "asset B");
        {
            uint256 supplyBefore = totalSupply;
            uint256 valueBefore;
            if (supplyBefore > 0) {
                (uint256 totalA, uint256 totalB) = ADAPTER.positionAmounts();
                valueBefore = totalA + totalB;
                if (valueBefore == 0) revert ZeroShares();
            }
            require(ASSET_A.transfer(address(ADAPTER), amountA), "asset A");
            require(ASSET_B.transfer(address(ADAPTER), amountB), "asset B");
            uint256 liquidityAdded;
            (liquidityAdded, usedA, usedB) = ADAPTER.addLiquidity(amountA, amountB, minA, minB);
            (uint256 addedA, uint256 addedB) = ADAPTER.amountsForLiquidity(liquidityAdded);
            uint256 addedValue = addedA + addedB;
            shares = supplyBefore == 0 ? addedValue * INITIAL_SCALE : addedValue * supplyBefore / valueBefore;
        }
        if (shares == 0) revert ZeroShares();
        balanceOf[msg.sender] += shares;
        totalSupply += shares;
        if (amountA > usedA) require(ASSET_A.transfer(msg.sender, amountA - usedA), "refund A");
        if (amountB > usedB) require(ASSET_B.transfer(msg.sender, amountB - usedB), "refund B");
        emit Deposit(msg.sender, usedA, usedB, shares);
    }

    function withdraw(uint256 shares, uint256 minA, uint256 minB, address receiver)
        external nonReentrant returns (uint256 amountA, uint256 amountB)
    {
        require(shares > 0 && receiver != address(0), "withdrawal");
        uint256 supply = totalSupply;
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        (amountA, amountB) = ADAPTER.removeLiquidity(shares, supply, minA, minB, receiver);
        emit Withdraw(msg.sender, receiver, shares, amountA, amountB);
    }

    function nav() external view returns (uint256) {
        (uint256 amountA, uint256 amountB) = ADAPTER.positionAmounts();
        return amountA + amountB;
    }
}
