// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAsset {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title BinExchange
contract BinExchange {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_BINS = 4;

    struct Bin {
        uint256 base;
        uint256 up;
        uint256 down;
        uint256 upBound;
        uint256 downBound;
        uint16 tollBps;
    }

    struct Book {
        uint256 liveTaken;
        uint256 liveOther;
        uint256 idleTaken;
        uint256 idleOther;
        uint256 weight;
    }

    struct Step {
        uint256 cashLeg;
        uint256 drop;
        uint256 qtyLeg;
        bool capped;
    }

    IAsset public immutable asset;
    address public immutable owner;

    Bin[] public bins;
    uint256 public ceilingBps;
    uint256 public feePot;
    uint256 public claimed;
    mapping(address => uint256) public purse;
    mapping(address => uint256) public upHeld;
    mapping(address => uint256) public downHeld;

    uint256 private locked;

    error BadConfig();
    error Slippage();
    error Expired();
    error TransferFailed();
    error Forbidden();
    error Reentered();

    modifier nonReentrant() {
        if (locked == 1) revert Reentered();
        locked = 1;
        _;
        locked = 0;
    }

    constructor(address asset_, uint256 ceiling, Bin[] memory seed) {
        if (asset_ == address(0)) revert BadConfig();
        if (seed.length == 0 || seed.length > MAX_BINS) revert BadConfig();
        if (ceiling == 0 || ceiling >= BPS) revert BadConfig();
        asset = IAsset(asset_);
        owner = msg.sender;
        ceilingBps = ceiling;

        uint256 backing;
        for (uint256 i; i < seed.length; ++i) {
            Bin memory bin = seed[i];
            if (bin.tollBps >= BPS) revert BadConfig();
            if (bin.base == 0 && bin.up == 0 && bin.down == 0) revert BadConfig();
            if (bin.up > type(uint256).max - bin.base) revert BadConfig();
            if (bin.down > type(uint256).max - bin.base) revert BadConfig();
            backing += bin.base;
            bins.push(bin);
        }
        if (backing == 0) revert BadConfig();
        _pull(msg.sender, backing);
    }

    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert BadConfig();
        _pull(msg.sender, amount);
        purse[msg.sender] += amount;
        claimed += amount;
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert BadConfig();
        purse[msg.sender] -= amount;
        claimed -= amount;
        _push(msg.sender, amount);
    }

    function collectFees(address to) external nonReentrant {
        if (msg.sender != owner) revert Forbidden();
        if (to == address(0)) revert BadConfig();
        uint256 amount = feePot;
        if (amount == 0) revert BadConfig();
        feePot = 0;
        _push(to, amount);
    }

    function buyUp(uint256 qty, uint256 maxPaid, uint256 minFilled, uint256 deadline)
        external
        nonReentrant
        returns (uint256 paid, uint256 filled)
    {
        (paid, filled) = _enter(true, true, qty, maxPaid, minFilled, deadline);
        purse[msg.sender] -= paid;
        claimed -= paid;
        upHeld[msg.sender] += filled;
    }

    function sellUp(uint256 qty, uint256 minReceived, uint256 minFilled, uint256 deadline)
        external
        nonReentrant
        returns (uint256 received, uint256 filled)
    {
        (received, filled) = _enter(false, false, qty, minReceived, minFilled, deadline);
        _credit(received);
        upHeld[msg.sender] -= filled;
    }

    function buyDown(uint256 qty, uint256 maxPaid, uint256 minFilled, uint256 deadline)
        external
        nonReentrant
        returns (uint256 paid, uint256 filled)
    {
        (paid, filled) = _enter(true, false, qty, maxPaid, minFilled, deadline);
        purse[msg.sender] -= paid;
        claimed -= paid;
        downHeld[msg.sender] += filled;
    }

    function sellDown(uint256 qty, uint256 minReceived, uint256 minFilled, uint256 deadline)
        external
        nonReentrant
        returns (uint256 received, uint256 filled)
    {
        (received, filled) = _enter(false, true, qty, minReceived, minFilled, deadline);
        _credit(received);
        downHeld[msg.sender] -= filled;
    }

    function reserves(bool drawUp)
        external
        view
        returns (uint256 liveTaken, uint256 liveOther, uint256 idleOther)
    {
        Book memory book = _compose(drawUp);
        return (book.liveTaken, book.liveOther, book.idleOther);
    }

    function binCount() external view returns (uint256) {
        return bins.length;
    }

    function collateralLocked() external view returns (uint256 sum) {
        uint256 n = bins.length;
        for (uint256 i; i < n; ++i) sum += bins[i].base;
    }

    function _credit(uint256 received) internal {
        uint256 free = asset.balanceOf(address(this)) - claimed - feePot;
        if (received > free) revert TransferFailed();
        purse[msg.sender] += received;
        claimed += received;
    }

    function _enter(
        bool acquire,
        bool drawUp,
        uint256 qty,
        uint256 limit,
        uint256 minFilled,
        uint256 deadline
    ) internal returns (uint256 cash, uint256 filled) {
        if (block.timestamp > deadline) revert Expired();
        (cash, filled) = _swap(acquire, drawUp, qty);
        bool worse = acquire ? cash > limit : cash < limit;
        if (filled == 0 || filled < minFilled || worse) revert Slippage();
    }

    function _swap(bool acquire, bool drawUp, uint256 qty) internal returns (uint256 cashMoved, uint256 filled) {
        uint256 left = qty;
        uint256 guard = bins.length + 2;
        while (left > 0 && guard > 0) {
            --guard;
            Book memory book = _compose(drawUp);
            if (book.liveTaken == 0 || book.weight == 0) break;

            Step memory step = _quote(acquire, drawUp, left, book);
            if (step.qtyLeg == 0 && step.drop == 0) {
                _squashDust(drawUp);
                continue;
            }
            if (step.qtyLeg > left) {
                step.cashLeg = _divUp(step.cashLeg * left, step.qtyLeg);
                step.qtyLeg = left;
            }
            if (acquire && step.qtyLeg > 0 && step.cashLeg == 0) step.cashLeg = 1;

            (uint256 toll, uint256 released) =
                this.settle(acquire, drawUp, step.qtyLeg, step.cashLeg, book.weight);
            feePot += toll;
            filled += step.qtyLeg;
            if (acquire) cashMoved += step.cashLeg + toll;
            else if (released > toll) cashMoved += released - toll;
            if (step.capped) break;
            left -= step.qtyLeg;
        }
    }

    function _quote(bool acquire, bool drawUp, uint256 left, Book memory book)
        internal
        view
        returns (Step memory step)
    {
        uint256 k = book.liveTaken * book.liveOther;
        uint256 stop = _nearestStop(drawUp, book.weight);
        uint256 cap = _ceiling(book.liveTaken, book.idleTaken, book.idleOther, k);
        uint256 room = stop < cap ? stop : cap;

        if (acquire) {
            step.cashLeg = _intake(book.liveTaken, book.liveOther, left);
            step.drop = left > step.cashLeg ? left - step.cashLeg : 0;
        } else {
            step.cashLeg = _refund(book.liveTaken, book.liveOther, left);
            step.drop = step.cashLeg;
        }
        if (step.drop <= room) {
            step.qtyLeg = left;
            return step;
        }

        step.capped = cap <= stop;
        step.drop = step.capped ? cap : stop;
        uint256 nextTaken = book.liveTaken > step.drop ? book.liveTaken - step.drop : 0;
        if (nextTaken == 0) nextTaken = 1;
        uint256 nextOther = acquire ? _divUp(k, nextTaken) : k / nextTaken;
        if (acquire) {
            step.cashLeg = nextOther > book.liveOther ? nextOther - book.liveOther : 0;
            step.qtyLeg = step.drop + step.cashLeg;
        } else {
            step.cashLeg = step.drop;
            uint256 grown = nextOther > book.liveOther ? nextOther - book.liveOther : 0;
            step.qtyLeg = grown + step.drop;
        }
    }

    function _compose(bool drawUp) internal view returns (Book memory book) {
        uint256 n = bins.length;
        for (uint256 i; i < n; ++i) {
            uint256 taken = _free(i, drawUp);
            uint256 other = _free(i, !drawUp);
            if (taken > 0) {
                book.liveTaken += taken;
                book.liveOther += other;
                book.weight += _weight(i);
            } else {
                book.idleTaken += taken;
                book.idleOther += other;
            }
        }
    }

    function _nearestStop(bool drawUp, uint256 weight) internal view returns (uint256 stop) {
        stop = type(uint256).max;
        uint256 n = bins.length;
        for (uint256 i; i < n; ++i) {
            uint256 free = _free(i, drawUp);
            if (free == 0) continue;
            uint256 drop = free * weight / _weight(i);
            if (drop < stop) stop = drop;
        }
        if (stop == type(uint256).max) stop = 0;
    }

    function _ceiling(uint256 liveTaken, uint256 idleTaken, uint256 idleOther, uint256 k)
        internal
        view
        returns (uint256 room)
    {
        uint256 hi = ceilingBps;
        uint256 lo = BPS - hi;
        uint256 shifted = lo * idleOther / hi;
        uint256 extra = (4 * lo * k) / hi;
        uint256 star;
        if (idleTaken >= shifted) {
            uint256 linear = idleTaken - shifted;
            uint256 root = _root(linear * linear + extra);
            star = root > linear ? (root - linear) / 2 : 0;
        } else {
            uint256 linear = shifted - idleTaken;
            uint256 root = _root(linear * linear + extra);
            star = (linear + root) / 2;
        }
        room = liveTaken > star ? liveTaken - star : 0;
    }

    function _intake(uint256 taken, uint256 other, uint256 qty) internal pure returns (uint256 cash) {
        uint256 span = taken + other;
        bool above = span >= qty;
        uint256 gap = above ? span - qty : qty - span;
        uint256 root = _rootUp(gap * gap + 4 * qty * other);
        if (above) cash = root > gap ? _divUp(root - gap, 2) : 0;
        else cash = _divUp(root + gap, 2);
    }

    function _refund(uint256 taken, uint256 other, uint256 qty) internal pure returns (uint256 cash) {
        uint256 span = taken + other + qty;
        uint256 root = _rootUp(span * span - 4 * qty * taken);
        cash = span > root ? (span - root) / 2 : 0;
    }

    function settle(bool acquire, bool drawUp, uint256 qtyLeg, uint256 cashLeg, uint256 weight)
        external
        returns (uint256 toll, uint256 released)
    {
        if (msg.sender != address(this)) revert Forbidden();
        uint256 n = bins.length;
        uint256 active;
        for (uint256 i; i < n; ++i) {
            if (_free(i, drawUp) > 0) ++active;
        }

        uint256 cashLeft = cashLeg;
        uint256 qtyLeft = qtyLeg;
        uint256 seen;
        for (uint256 i; i < n; ++i) {
            if (_free(i, drawUp) == 0) continue;
            ++seen;
            uint256 shareCash;
            uint256 shareQty;
            if (seen == active) {
                shareCash = cashLeft;
                shareQty = qtyLeft;
            } else {
                uint256 w = _weight(i);
                shareCash = cashLeg * w / weight;
                shareQty = qtyLeg * w / weight;
                cashLeft -= shareCash;
                qtyLeft -= shareQty;
            }
            uint256 fee = _toll(shareCash, bins[i].tollBps);
            toll += fee;
            if (acquire) {
                bins[i].base += shareCash;
                _pullInventory(i, drawUp, shareQty);
            } else {
                if (drawUp) bins[i].down += shareQty;
                else bins[i].up += shareQty;
                _fold(i);
                bins[i].base -= shareCash;
                released += shareCash;
            }
        }
    }

    function _toll(uint256 cash, uint16 bps) internal pure returns (uint256 fee) {
        if (bps == 0 || cash == 0) return 0;
        fee = _divUp(cash * uint256(bps), BPS);
        if (fee > cash) fee = cash;
    }

    function _pullInventory(uint256 i, bool drawUp, uint256 amount) internal {
        Bin storage b = bins[i];
        if (drawUp) {
            if (b.up < amount) {
                uint256 short = amount - b.up;
                b.base -= short;
                b.up += short;
                b.down += short;
            }
            b.up -= amount;
        } else {
            if (b.down < amount) {
                uint256 short = amount - b.down;
                b.base -= short;
                b.up += short;
                b.down += short;
            }
            b.down -= amount;
        }
    }

    function _fold(uint256 i) internal {
        Bin storage b = bins[i];
        uint256 matched = b.up < b.down ? b.up : b.down;
        if (matched == 0) return;
        b.up -= matched;
        b.down -= matched;
        b.base += matched;
    }

    function _squashDust(bool drawUp) internal {
        uint256 n = bins.length;
        for (uint256 i; i < n; ++i) {
            uint256 free = _free(i, drawUp);
            if (free == 0 || free > 1) continue;
            if (drawUp) bins[i].upBound = bins[i].up + bins[i].base;
            else bins[i].downBound = bins[i].down + bins[i].base;
        }
    }

    function _free(uint256 i, bool upSide) internal view returns (uint256) {
        Bin storage b = bins[i];
        uint256 gross = upSide ? b.up + b.base : b.down + b.base;
        uint256 bound = upSide ? b.upBound : b.downBound;
        return gross > bound ? gross - bound : 0;
    }

    function _weight(uint256 i) internal view returns (uint256) {
        Bin storage b = bins[i];
        return b.up + b.down + b.base + b.base;
    }

    function _pull(address from, uint256 amount) internal {
        uint256 start = asset.balanceOf(address(this));
        _raw(abi.encodeWithSelector(IAsset.transferFrom.selector, from, address(this), amount));
        if (asset.balanceOf(address(this)) != start + amount) revert TransferFailed();
    }

    function _push(address to, uint256 amount) internal {
        uint256 start = asset.balanceOf(address(this));
        _raw(abi.encodeWithSelector(IAsset.transfer.selector, to, amount));
        if (asset.balanceOf(address(this)) != start - amount) revert TransferFailed();
    }

    function _raw(bytes memory data) internal {
        (bool ok, bytes memory ret) = address(asset).call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _divUp(uint256 n, uint256 d) internal pure returns (uint256) {
        return n == 0 ? 0 : (n - 1) / d + 1;
    }

    function _root(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) >> 1;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) >> 1;
        }
    }

    function _rootUp(uint256 x) internal pure returns (uint256 y) {
        y = _root(x);
        if (y == 0) return x == 0 ? 0 : 1;
        if (x / y == y && x % y == 0) return y;
        return y + 1;
    }
}