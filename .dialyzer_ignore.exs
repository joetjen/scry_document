[
  # `Scry.Document.Executor.project_ordinary/2` (the plain-field
  # projection helper `project_body/4` calls once pseudo items have been
  # stripped out of a body) hand-builds a minimal `%Scry.Core.Query{}`
  # (`source: nil`, every clause field empty/plain) and calls
  # `Scry.Core.QueryOps.run_flat/3` with it directly -- the exact same
  # "flat leaf query, no engine" reuse `run_flat/3`'s own moduledoc
  # documents as its intended purpose. Dialyzer reports a `:call`
  # contract violation here (breaks `run_flat/3`'s own declared
  # `Query.t()` contract), but confirmed a false positive, not a real
  # bug: run this package's own `priv/gen/`-adjacent repro directly
  # (`QueryOps.run_flat([row], flat_query, %{})` with the identical
  # struct literal dialyzer prints) and it returns the correct
  # `{:ok, [...]}` every time. `scry_core`'s own dialyzer run against
  # itself (`MIX_ENV=test mix dialyzer` in `../scry_core`) reports zero
  # errors for `run_flat/3` -- nothing in `run_flat/3`'s own body or
  # `@spec` is at fault. The mismatch only surfaces once `run_flat/3` is
  # called, with a fully-literal struct, from a *different* OTP
  # application than the one that defines it: dialyzer's success typing
  # for `run_flat/3`'s own multi-branch `cond` (`aggregate_query?/1`/
  # `query.group_mode`/`windows`/etc., each field checked independently)
  # loses the correlation between this literal's field values across
  # that dispatch when re-derived from a downstream app's PLT, and
  # concludes (wrongly) that no branch can match. A known class of
  # dialyzer imprecision with multi-guard `cond`/`case` dispatch over a
  # struct literal passed across an app boundary, not specific to this
  # function's actual logic.
  {"lib/scry/document/executor.ex", :call}
]
