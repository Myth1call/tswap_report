### [M-1] Deadline is not enforced in `TSwapPool::deposit`

**Description:**

The `deposit` function accepts a `deadline` parameter and documents it in NatSpec as *"The deadline for the transaction to be completed by"*, but never validates it. Unlike `withdraw`, `swapExactInput`, and `swapExactOutput`, `deposit` does not apply the existing `revertIfDeadlinePassed` modifier.

```solidity
modifier revertIfDeadlinePassed(uint64 deadline) {
    if (deadline < uint64(block.timestamp)) {
        revert TSwapPool__DeadlineHasPassed(deadline);
    }
    _;
}

function deposit(..., uint64 deadline)
    external
    revertIfZero(wethToDeposit)   // deadline NOT checked
    returns (uint256 liquidityTokensToMint)
{ ... }

function withdraw(..., uint64 deadline)
    external
    revertIfDeadlinePassed(deadline)  // deadline checked ✅
    ...
```

Users and frontends pass `deadline` expecting the transaction to revert if mined after that timestamp. On `deposit`, the parameter is **dead code**: a transaction signed with `deadline = block.timestamp + 300` can still execute hours or days later, as long as other checks (`minimumLiquidityTokensToMint`, `maximumPoolTokensToDeposit`, etc.) pass at execution time.

This breaks the standard Uniswap-style safety model where deadline protects against stale mempool transactions, delayed execution, and adverse pool-state changes after the user signed.

**Impact:**

Users can be executed at **unintended times and pool conditions**:

- **Stale transactions:** A deposit tx stuck in the mempool (low gas, network congestion) can execute when the pool ratio has moved significantly. Slippage bounds may still pass, but the user never intended to deposit at that later state.
- **MEV / manipulation:** An attacker can wait for favorable pool movement and ensure a pending deposit executes after manipulation, within the user’s slippage tolerances.
- **False security:** Integrators set `deadline` believing it is enforced; users are not protected on the add-liquidity path while being protected on withdraw and swap — inconsistent and misleading API.

While `minimumLiquidityTokensToMint` and `maximumPoolTokensToDeposit` limit ratio slippage at execution time, they do **not** replace a deadline: a user may accept “no deposit after time T” regardless of whether slippage bounds would still pass.

**Proof of Concept:**

1. User prepares `deposit(weth, minLp, maxPoolToken, deadline)` with `deadline = block.timestamp + 300` (5 minutes).
2. The transaction is not mined immediately (low priority fee).
3. After 2 hours, pool reserves change due to swaps, but user’s `minimumLiquidityTokensToMint` / `maximumPoolTokensToDeposit` still allow execution.
4. The deposit **succeeds** even though `block.timestamp > deadline`.

On `withdraw` with the same stale pattern, the call would revert with `TSwapPool__DeadlineHasPassed`.

**Recommended Mitigation:**

Apply the same modifier used elsewhere in the contract:

```diff
function deposit(
    uint256 wethToDeposit,
    uint256 minimumLiquidityTokensToMint,
    uint256 maximumPoolTokensToDeposit,
    uint64 deadline
)
    external
    revertIfZero(wethToDeposit)
+   revertIfDeadlinePassed(deadline)
    returns (uint256 liquidityTokensToMint)
{
    ...
}
```

Ensure all user-facing state-changing functions that accept `deadline` enforce it consistently.

## Likelihood & Impact:
**IMPACT:** Medium — missing deadline on `deposit` can lead to liquidity added at an unintended time or pool state, but `minimumLiquidityTokensToMint` and `maximumPoolTokensToDeposit` still cap ratio slippage at execution. Unlike swaps, the user is not taking a one-sided trade at a quoted price; risk is mainly stale execution and UX/API inconsistency, not immediate drain of funds.
**LIKELIHOOD:** Medium — delayed mining and mempool exposure are realistic on mainnet, though slippage bounds often prevent the worst outcomes.
**Severity:** Medium

### [I-1] `PoolFactory::PoolFactory__PoolDoesNotExist` is not used and should be removed

**Description:**

The `PoolFactory` contract declares a custom error `PoolFactory__PoolDoesNotExist` but never reverts with it anywhere in the smart contract. The only pool-existence check in the factory is in `createPool`, which uses the sibling error `PoolFactory__PoolAlreadyExists` when a pool for a token already exists.

When a caller queries a pool that was never created, `getPool` and `getToken` silently return `address(0)` instead of reverting with `PoolFactory__PoolDoesNotExist`. The unused error is dead code: it increases bytecode size slightly, adds noise for auditors and integrators, and suggests an intended revert path that was never implemented.

```solidity
error PoolFactory__PoolAlreadyExists(address tokenAddress);
error PoolFactory__PoolDoesNotExist(address tokenAddress); // declared, never used

function getPool(address tokenAddress) external view returns (address) {
    return s_pools[tokenAddress]; // returns address(0) if missing
}
```

**Impact:**

No direct security impact or loss of funds. This is a code-quality and maintainability issue. Integrators reading the interface may assume the error is part of the contract’s revert API and write handling logic for a path that can never occur. Leaving unused errors in production code also makes future refactors harder because it is unclear whether the error was forgotten or intentionally reserved.

**Proof of Concept:**

1. Inspect `PoolFactory.sol` — `PoolFactory__PoolDoesNotExist` is defined at line 23.
2. Search the repository for `PoolFactory__PoolDoesNotExist` — it appears only in the declaration, never in a `revert` statement.
3. Call `getPool(address(0x1234...))` for a token that has no pool — the call succeeds and returns `address(0)`; no custom error is ever emitted.

**Recommended Mitigation:**

Either remove the unused error:

```diff
-    error PoolFactory__PoolDoesNotExist(address tokenAddress);
```

Or, if explicit failure on missing pools is desired, use it in view helpers:

```solidity
function getPool(address tokenAddress) external view returns (address) {
    address pool = s_pools[tokenAddress];
    if (pool == address(0)) {
        revert PoolFactory__PoolDoesNotExist(tokenAddress);
    }
    return pool;
}
```

Pick one approach and keep the API consistent across `getPool` and `getToken`.

## Likelihood & Impact:
**IMPACT:** None — no exploit path or user fund loss.
**LIKELIHOOD:** N/A — informational finding; not an exploitable condition.
**Severity:** Informational
**Severity:** Informational

### [I-2] Zero address check is missing in `PoolFactory` constructor

**Description:**

The `PoolFactory` constructor accepts a `wethToken` address and stores it as an immutable `i_wethToken` without validating that it is not `address(0)`. Because `i_wethToken` is immutable, a mistaken deployment with a zero address is permanent and cannot be corrected without redeploying the entire factory.

If the factory is deployed with `address(0)`, all pools will reference an invalid WETH token. Deposits, swaps, and withdrawals that rely on WETH transfers will revert or behave incorrectly, effectively bricking the protocol.

**Impact:**

This is a defensive-coding issue: fail fast at deployment rather than silently accepting invalid state.

**Proof of Concept:**

Deploy the factory with a zero WETH address and create a pool:

```solidity
PoolFactory factory = new PoolFactory(address(0));
address pool = factory.createPool(address(tokenA));

// i_wethToken is permanently address(0)
assert(factory.getWethToken() == address(0));
```

Any `TSwapPool` created from this factory inherits `address(0)` as its WETH token. WETH-related operations in the pool will fail when the contract attempts `transfer` / `transferFrom` on the zero address.

**Recommended Mitigation:**

Add an explicit zero-address check in the constructor and revert with a dedicated custom error:

```diff
+error PoolFactory__ZeroAddress();

constructor(address wethToken) {
+   if (wethToken == address(0)) {
+       revert PoolFactory__ZeroAddress();
+   }
    i_wethToken = wethToken;
}
```

Alternatively, use OpenZeppelin's `Address` helpers or a shared `ZeroAddress` modifier if the project already uses that pattern elsewhere.

## Likelihood & Impact:
**IMPACT:** Low — does not enable theft by itself, but a bad deployment bricks all pools created by the factory.
**LIKELIHOOD:** Low — requires deployer or script error; not triggerable by arbitrary users after correct deployment.
**Severity:** Informational
### [I-3] `PoolFactory::createPool` lacks safe handling when `IERC20(tokenAddress).name()` reverts

**Description:**

In `createPool`, the factory calls `IERC20(tokenAddress).name()` twice without validation or fallback logic. The return value is used to build the LP token name and symbol for the new `TSwapPool`:

```solidity
string memory liquidityTokenName = string.concat("T-Swap ", IERC20(tokenAddress).name());
```

`name()` is part of the optional ERC-20 metadata extension (`IERC20Metadata`), not the core ERC-20 interface. Many valid ERC-20 tokens implement only `transfer`, `approve`, and `balanceOf`. For such tokens — or for malformed / non-contract addresses — the external call to `name()` will revert and **`createPool` becomes unusable** for that token.

There is also no handling for:
- **`address(0)`** or an EOA passed as `tokenAddress` (call to non-contract reverts)
- **Empty string** return (pool still deploys, but LP metadata is meaningless, e.g. `"T-Swap "`)

Because `createPool` is permissionless, any token without a working `name()` cannot get a pool through this factory, even if the token is otherwise safe to trade.

**Impact:**

The impact is **availability / compatibility**:

This is a robustness and UX issue, not a critical security flaw, assuming standard OpenZeppelin-style tokens are used.

**Proof of Concept:**

1. Deploy a minimal ERC-20 without `name()` (only core ERC-20 functions).
2. Call `factory.createPool(address(minimalToken))`.
3. The transaction reverts when the factory calls `name()` on the token.

Alternatively, call `createPool(address(0))` or `createPool(address(0x1234...))` (EOA) — the external call reverts because there is no contract code implementing `name()`.

**Recommended Mitigation:**

Use `try/catch` with sensible fallbacks, or accept `name` / `symbol` as constructor parameters from the caller:

```diff
+function _safeName(address token) private view returns (string memory) {
+    try IERC20Metadata(token).name() returns (string memory n) {
+        if (bytes(n).length == 0) return "Unknown";
+        return n;
+    } catch {
+        return "Unknown";
+    }
+}
+function _safeSymbol(address token) private view returns (string memory) {
+    try IERC20Metadata(token).symbol() returns (string memory s) {
+        if (bytes(s).length == 0) return "UNK";
+        return s;
+    } catch {
+        return "UNK";
+    }
+}
```

```diff
+string memory liquidityTokenName = string.concat("T-Swap ", _safeName(tokenAddress));
+string memory liquidityTokenSymbol = string.concat("ts", _safeSymbol(tokenAddress));
```

Also consider validating `tokenAddress.code.length > 0` before external metadata calls.

## Likelihood & Impact:
**IMPACT:** Low — pool creation fails for affected tokens; no user fund loss in existing pools.
**LIKELIHOOD:** Low — only affects non-standard ERC-20s or invalid addresses; common tokens (OpenZeppelin, etc.) implement `name()`.
**Severity:** Informational

### [I-4] `PoolFactory::createPool` uses `name()` instead of `symbol()` for LP token symbol

**Description:**

When creating a new pool, `PoolFactory` builds metadata for the LP token (the `TSwapPool` ERC-20) from the underlying pool token’s ERC-20 metadata. The **name** field is constructed correctly, but the **symbol** field incorrectly calls `name()` a second time instead of `symbol()`:

```solidity
string memory liquidityTokenSymbol = string.concat("ts",IERC20(tokenAddress).name()); // should be symbol()
```

**Impact:**

No direct loss of funds or broken core swap/deposit logic — the pool still functions. The impact is **incorrect off-chain representation and poor UX**:

**Proof of Concept:**

1. Deploy a token with distinct `name` and `symbol`, e.g. OpenZeppelin `ERC20("USD Coin", "USDC")`.
2. Call `factory.createPool(address(token))`.
3. Read the deployed pool’s ERC-20 metadata:

```solidity
TSwapPool pool = TSwapPool(factory.getPool(address(token)));

assertEq(pool.name(),   "T-Swap USD Coin");  // correct
assertEq(pool.symbol(), "tsUSD Coin");       // incorrect — expected "tsUSDC"
```

The symbol contains the full token **name**, not the token **symbol**.

**Recommended Mitigation:**

Use `symbol()` when building the LP token symbol. Import `IERC20Metadata` (OpenZeppelin) instead of bare `IERC20` if needed:

```diff
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

string memory liquidityTokenName   = string.concat("T-Swap ", IERC20Metadata(tokenAddress).name());
-string memory liquidityTokenSymbol = string.concat("ts",     IERC20Metadata(tokenAddress).name());
+string memory liquidityTokenSymbol = string.concat("ts",     IERC20Metadata(tokenAddress).symbol());
```

Combine with the `try/catch` fallbacks from [I-3] if non-standard tokens should still be supported.

## Likelihood & Impact:
**IMPACT:** Low — wrong LP token labeling; core protocol math and custody unaffected.
**LIKELIHOOD:** High — affects **every** pool created through the factory by design.
**Severity:** Informational

### [I-5] Redundant `minimumWethDeposit` argument in `TSwapPool__WethDepositAmountTooLow`

**Description:**

The custom error `TSwapPool__WethDepositAmountTooLow` declares two parameters, but the minimum WETH deposit is a **fixed protocol constant** that never changes at runtime:

```solidity
uint256 private constant MINIMUM_WETH_LIQUIDITY = 1_000_000_000;

error TSwapPool__WethDepositAmountTooLow(
    uint256 minimumWethDeposit,  // always MINIMUM_WETH_LIQUIDITY
    uint256 wethToDeposit
);

if (wethToDeposit < MINIMUM_WETH_LIQUIDITY) {
    revert TSwapPool__WethDepositAmountTooLow(
        MINIMUM_WETH_LIQUIDITY,
        wethToDeposit
    );
}
```

Every revert passes the same constant value (`1_000_000_000` wei ≈ 1 gwei) as the first argument. That value is already exposed via `getMinimumWethDepositAmount()` and is not context-dependent like slippage errors (`actual` vs `min`). Including it in the error duplicates on-chain information, increases revert calldata size slightly, and makes error handling inconsistent with errors that only carry dynamic values (e.g. `TSwapPool__OutputTooLow(uint256 actual, uint256 min)` where both values differ per call).

**Impact:**

No security impact or fund loss. This is a **code quality and gas-efficiency** issue.

**Proof of Concept:**

1. Inspect `TSwapPool.sol` — `MINIMUM_WETH_LIQUIDITY` is a `private constant`.
2. Call `deposit` with `wethToDeposit < 1_000_000_000`.
3. The revert data always encodes `minimumWethDeposit = 1000000000` regardless of pool state, token, or caller.

Compare with reading the minimum directly:

```solidity
uint256 min = pool.getMinimumWethDepositAmount(); // same value, no revert needed
```

**Recommended Mitigation:**

Remove the redundant parameter and keep only the user-supplied amount that failed the check:

```diff

error TSwapPool__WethDepositAmountTooLow(
-   uint256 minimumWethDeposit,
    uint256 wethToDeposit
);

if (wethToDeposit < MINIMUM_WETH_LIQUIDITY) {
    revert TSwapPool__WethDepositAmountTooLow(
-               MINIMUM_WETH_LIQUIDITY,
                wethToDeposit
            );
}
```

Integrators that need the threshold can call `getMinimumWethDepositAmount()` or document the constant. Alternatively, use a parameterless error if no dynamic data is required:

```solidity
error TSwapPool__WethDepositAmountTooLow();
```

## Likelihood & Impact:
**IMPACT:** None — cosmetic / minor gas on revert paths only.
**LIKELIHOOD:** N/A — design choice, not an exploitable condition.
**Severity:** Informational
### [I-6] Three arguments in `TSwapPool::swap` event should be indexed

**Description:**

The `Swap` event declares five parameters but only `swapper` is marked `indexed`. The token addresses and amounts are emitted as non-indexed data:

```solidity
event Swap(
    address indexed swapper,
    IERC20 tokenIn,
    uint256 amountTokenIn,
    IERC20 tokenOut,
    uint256 amountTokenOut
);
```

In the EVM log model, each `indexed` argument becomes a **topic** and can be used in efficient `eth_getLogs` filters. Non-indexed arguments are stored only in the log **data** payload and cannot be filtered on-chain without scanning every log from the contract.

Because `Swap` has more than three parameters total, the most filter-relevant fields should use the three available indexed slots (Solidity’s per-event maximum): the caller (`swapper`), the input token (`tokenIn`), and the output token (`tokenOut`). The two `uint256` amounts should remain non-indexed — they are execution-specific values that integrators read from log data, not typical filter keys.

**Impact:**

No direct security impact or loss of funds. The impact is **off-chain observability and integrator UX**:

**Proof of Concept:**

Inspect `TSwapPool.sol` — `Swap` indexes only `swapper`; `tokenIn` and `tokenOut` are plain `IERC20` parameters without `indexed`.
**Recommended Mitigation:**

Index `tokenIn` and `tokenOut` alongside `swapper`, keeping amounts in the data section:

```diff
event Swap(
    address indexed swapper,
-   IERC20 tokenIn,
+   IERC20 indexed tokenIn,
    uint256 amountTokenIn,
-   IERC20 tokenOut,
+   IERC20 indexed tokenOut,
    uint256 amountTokenOut
);
```

This uses all three allowed indexed parameters. No change is required at the `emit Swap(...)` call site — argument order and types stay the same.

**Note:** Changing event signatures is a **breaking change** for existing indexers and subgraphs. If the protocol is already deployed, coordinate a versioned ABI update; for pre-deployment code, apply the fix before release.

## Likelihood & Impact:
**IMPACT:** None — affects log filtering and off-chain tooling only; on-chain swap logic is unchanged.
**LIKELIHOOD:** N/A — informational finding; not an exploitable condition.
**Severity:** Informational

### [I-7] Redundant `balanceOf` calls in `TSwapPool::deposit` waste gas

**Description:**

In the non-initial `deposit` branch (`totalLiquidityTokenSupply() > 0`), the contract reads pool reserves multiple times via external `balanceOf` calls when two reads would suffice.

```solidity
if (totalLiquidityTokenSupply() > 0) {
    uint256 wethReserves = i_wethToken.balanceOf(address(this));
    uint256 poolTokenReserves = i_poolToken.balanceOf(address(this)); // never used in code

    uint256 poolTokensToDeposit = getPoolTokensToDepositBasedOnWeth(wethToDeposit);
    // ...
    liquidityTokensToMint =
        (wethToDeposit * totalLiquidityTokenSupply()) / wethReserves;
}
```

Two separate issues compound the waste:

1. **Dead read on line 135:** `poolTokenReserves` is assigned but never used in executable code — it appears only in NatSpec-style math comments. Every subsequent deposit pays for an extra ERC-20 `CALL` that has no effect on the outcome.

2. **Duplicate reads inside `getPoolTokensToDepositBasedOnWeth`:** That helper performs both `balanceOf` calls again:

```solidity
function getPoolTokensToDepositBasedOnWeth(uint256 wethToDeposit) public view returns (uint256) {
    uint256 poolTokenReserves = i_poolToken.balanceOf(address(this));
    uint256 wethReserves = i_wethToken.balanceOf(address(this));
    return (wethToDeposit * poolTokenReserves) / wethReserves;
}
```

So each `deposit` after pool initialization performs **four** `balanceOf` external calls when **two** are enough: `wethReserves` is fetched twice (lines 133 and inside the helper), and `poolTokenReserves` is fetched twice (line 135 unused + inside the helper).

`getPoolTokensToDepositBasedOnWeth` is useful as a standalone **view** for frontends and integrators, but calling it from `deposit` duplicates work already partially done in the caller.

**Impact:**

No security impact or incorrect accounting — deposits still compute the right `poolTokensToDeposit` and `liquidityTokensToMint`. The impact is **gas inefficiency on a core user path**:

- Up to **two redundant external calls** per `deposit` (one entirely dead, one duplicate `wethReserves` read).
- ERC-20 `balanceOf` is a cross-contract `CALL`; cost depends on the token implementation but is non-trivial on every add-liquidity transaction.
- Users pay more gas than necessary for a frequently used operation.

**Proof of Concept:**

1. Inspect `deposit` — `poolTokenReserves` on line 135 is not referenced after assignment except in comments.
2. Trace `getPoolTokensToDepositBasedOnWeth` — it re-fetches both token balances.
3. Count external `balanceOf` calls in the `totalLiquidityTokenSupply() > 0` branch: **4** (`weth` ×2, `poolToken` ×2).
4. The minimum required for both formulas is **2** (one read per reserve, shared across `poolTokensToDeposit` and `liquidityTokensToMint`).

**Recommended Mitigation:**

Read each reserve once in `deposit` and inline both calculations. Keep `getPoolTokensToDepositBasedOnWeth` for external callers only:

```diff
if (totalLiquidityTokenSupply() > 0) {
    uint256 wethReserves = i_wethToken.balanceOf(address(this));
    uint256 poolTokenReserves = i_poolToken.balanceOf(address(this));

-   uint256 poolTokensToDeposit = getPoolTokensToDepositBasedOnWeth(wethToDeposit);
+   uint256 poolTokensToDeposit =
+       (wethToDeposit * poolTokenReserves) / wethReserves;

    // ... slippage checks unchanged ...

    liquidityTokensToMint =
        (wethToDeposit * totalLiquidityTokenSupply()) / wethReserves;
}
```

Alternatively, add an internal overload that accepts pre-fetched reserves:

```solidity
function _poolTokensToDeposit(
    uint256 wethToDeposit,
    uint256 wethReserves,
    uint256 poolTokenReserves
) private pure returns (uint256) {
    return (wethToDeposit * poolTokenReserves) / wethReserves;
}
```

and have the public `getPoolTokensToDepositBasedOnWeth` delegate to it after reading balances.

## Likelihood & Impact:
**IMPACT:** None — minor extra gas cost per deposit; no fund loss or logic error.
**LIKELIHOOD:** High — affects every non-initial `deposit` by design.
**Severity:** Informational 