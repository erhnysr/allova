# Security policy

Allova (formerly Allowance) has not had an independent audit. Use small balances.

**Report a vulnerability privately:** https://github.com/erhnysr/allova/security/advisories/new
Please do not open a public issue. Include the function, steps to reproduce and the impact.

## Fixed in 2.0.0

| v1 finding | v2 fix | Test |
|---|---|---|
| An intent signed before `removeAgent` or `revokeAgent` could be relayed after the key was re-added | Intent epochs (`StaleIntent`) | `test_regression_intentDoesNotSurvive*` |
| Payee rules (allowlist, caps, spent) survived `removeAgent` | New rule generation on removal | `test_regression_allowlistDoesNotSurviveRemove`, `test_regression_payeeCapSpentDoesNotSurviveRemove` |
| `setPayee(false)` did not stop payments in open mode | Explicit deny in both modes | `test_regression_setPayeeFalseDeniesInOpenMode` |

Thanks to KupiaSec for reporting the v1 findings.

## Known limits

- The token bucket allows a burst of up to about 2× `periodLimit` within one period
  (a full bucket plus one period of refill). `minInterval` bounds how fast that burst can be spent.
- The relayer of a `payWithSig` pays gas and can choose when (before the deadline) to relay.
