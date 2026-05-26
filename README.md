# operation_cr

A small Crystal shard for building **typed command objects** — classes with a
typed constructor (from `param` / `positional_param` macros) and a single
`perform` method whose return value is returned verbatim from `.call`.

Around that core sit five extensions:

- **`.with(...)`** — partial application that preserves types and validates
  kwarg keys at compile time (typo → compile error at *your* call site).
- **`.then(NextOp) { |r| {...} }`** — linear composition into a `Chain`.
- **`OperationCr::Pipeline`** — declarative `step Op` DSL with auto-merging
  NamedTuple context, `on_failure` and `before_step` hooks.
- **`.curry`** — one-arg-at-a-time application.
- **`.explain(...)`** — STDOUT (or any IO) tracer that prints an ASCII tree
  of nested operation calls with timings.

## What this is NOT

`operation_cr` is **not** a Trailblazer / Interactor / dry-monads port. If
you're looking for those features, this shard does not have them and is not
trying to:

- No `Result(T)` / `Success` / `Failure` type. `perform` returns whatever
  you want; if it raises, the exception propagates uncaught.
- No `halt` / `abort` semantics. The only way to stop a `Chain` or
  `Pipeline` mid-flight is `raise` from a step.
- No transactions / around hooks. `before_execute` / `after_execute` are
  pre/post-only — there's no `around { |&| db.transaction { yield } }`.
  (A `Pipeline` does have a `before_step` hook for per-step side effects,
  but no around-hook.)
- No exception swallowing — by design. Exceptions propagate or are caught
  by an explicit `on_failure` handler in a `Pipeline`.

What you get is a typed-constructor + partial-application + linear-pipeline
+ declarative-DSL + curry shard with a focus on **compile-time error
messages at the call site**.

## Installation

Add to your `shard.yml`:

```yaml
dependencies:
  operation_cr:
    github: stevegeek/operation-cr
```

Then `shards install`.

## Quick start

```crystal
require "operation_cr"

class GreetUser < OperationCr::Operation
  param name : String
  param greeting : String = "Hello"

  def perform
    "#{greeting}, #{name}!"
  end
end

GreetUser.call(name: "World")                  # => "Hello, World!"
GreetUser.call(name: "Alice", greeting: "Hi")  # => "Hi, Alice!"
```

### Positional + keyword params

```crystal
class Add < OperationCr::Operation
  positional_param a : Int32
  positional_param b : Int32 = 0      # optional positional (must come after required)
  param multiplier : Int32 = 1        # keyword, optional

  def perform : Int32
    (a + b) * multiplier
  end
end

Add.call(2, 3)                  # => 5
Add.call(2, 3, multiplier: 10)  # => 50
```

A required `positional_param` after an optional one is a compile-time error
naming both params — see `examples/should_fail_pos_order.cr`.

### Partial application — `.with`

`.with` validates kwarg keys at compile time against the operation's
declared params. A typo is a compile error at *your* call site:

```crystal
welcomer = GreetUser.with(greeting: "Welcome")
welcomer.call(name: "Bob")            # => "Welcome, Bob!"

# Compile error: "unknown param `grete` for GreetUser. Valid params: name, greeting"
GreetUser.with(grete: "Hi")           # see examples/should_fail_typo.cr
```

### Composition — `.then`

`.then` builds a `Chain`. The block converts the previous step's result
into a `NamedTuple` of kwargs for the next op. A block-only form is also
supported.

```crystal
chain = Add
  .then(Format) { |n| {value: n} }
  .then(Shout)  { |s| {text: s}  }
  .then        { |s| s.downcase }   # block-only transform

chain.call(2, 3, multiplier: 10)
# => "result=50!"
```

`Chain` also supports `.with` for partial application of the head op's args
(positional + keyword), with the same compile-time key validation.

### Declarative pipelines — `OperationCr::Pipeline`

For workflows of 3+ steps with hooks between them, `Pipeline` is more
declarative than `.then` chaining. Subclass `OperationCr::Pipeline`, list
your steps with `step Op`, and call it with `.call(**initial_context)`:

```crystal
class PublishPipeline < OperationCr::Pipeline
  step CloneRepo        # returns {working_tree:, commit_sha:}
  step ParseShardYml    # needs {working_tree:}, returns {version:}
  step BuildTarball     # needs {working_tree:}, returns {bytes:}
  step HashBytes        # needs {bytes:}, returns {sha256:, size:}
  step PersistVersion   # needs {version:, sha256:, size:, ...}

  before_step do |ctx, step_name|
    # Per-step side effect: status writes, logging, instrumentation
    ctx[:job].as(PublishJob).update(status: STEP_STATUS[step_name])
  end

  on_failure do |ex, step_name|
    # Exception-based; raise to propagate, return value to replace result
    Log.error(exception: ex) { "pipeline failed at #{step_name}" }
    nil
  end
end

PublishPipeline.call(
  job:      job,
  repo_url: "https://...",
  git_ref:  "main",
)
# => {job: ..., repo_url: ..., git_ref: ..., working_tree: ...,
#     commit_sha: ..., version: ..., bytes: ..., sha256: ..., size: ...,
#     package_version: ...}
```

**Context model.** The initial kwargs to `.call` form a `NamedTuple`
context. Each step's `perform` must return a `NamedTuple` (use
`NamedTuple.new` for void steps); that tuple is merged into the context.
Subsequent steps slice their `param` kwargs from the merged context. A
step requesting a key that no prior step has added is a compile error.

**Failure handling** is exception-based. Without `on_failure`, exceptions
propagate out of `.call`. With it, the block receives the exception and
the step's name (Symbol); its return value becomes the pipeline's return.

**Step naming.** `step Op` derives the step name from the operation's
class basename (`Publish::Operations::CloneRepo` → `:clone_repo`). Use
`step :name, Op` for an explicit name passed to `on_failure` / `before_step`.

**Compile-time guards:**

- Subclassing a `Pipeline` subclass is rejected — the per-subclass step
  accumulator wouldn't carry parent steps and hooks would silently drop.
  Subclass `OperationCr::Pipeline` directly.
- Step operations using `positional_param` are rejected — pipelines pass
  kwargs only.
- Duplicate `on_failure` or `before_step` definitions in one Pipeline
  subclass are rejected (would silently overwrite).

**Introspection.** `MyPipeline.step_names` returns the ordered list of
step names — useful for diagnostics, status-table validation, or
generating documentation.

**Pipeline vs `.then` chain.** `.then` is good for 2-3 operations
composed dynamically with custom kwarg mapping. `Pipeline` is better for
larger workflows where you want declarative step lists, hooks between
steps, and centralised failure handling.

### Currying — `.curry`

Consume one arg at a time. Each step returns either a new `Curried` or —
once every required param is bound — the operation's result.

```crystal
class CurryAdd < OperationCr::Operation
  positional_param a : Int32
  positional_param b : Int32

  def perform; a + b; end
end

step = CurryAdd.curry.call(2)          # => Curried(...)
step.as(OperationCr::Curried).call(3)  # => 5
```

Note that each curried step is a different concrete generic type, so
inter-step values usually need an `.as(OperationCr::Curried)` cast. If
you want to *hold* a partially-applied operation as a value, prefer
`.with` — chain steps allocate a fresh `Curried` per arg, whereas `.with`
just appends to one held tuple.

### Tracing — `.explain`

```crystal
GreetUser.explain(name: "Alice", greeting: "Welcome")
# Prints to STDOUT (or pass io: ...):
#
#   GreetUser(name: "Alice", greeting: "Welcome") → "Welcome, Alice!" (0.12ms)
```

Nested operation calls are traced as children of the outer one — you get
the full call tree. Tracing state is fiber-local, so concurrent `.explain`
calls don't cross-contaminate.

## Lifecycle hooks

```
new(...) -> prepare         # eager, at construction
call    -> before_execute  # deferred, on .call
         -> perform
         -> after_execute
```

- `prepare` runs at construction time (eagerly). Override for derived state.
- `before_execute` / `after_execute` wrap `perform` on every `.call`.
- **Do not change `after_execute`'s return type.** `Chain` infers chain-step
  types from `typeof(perform)`; returning a wrapped/envelope type from
  `after_execute` will silently break composition. See the doc-comment in
  `src/operation_cr/operation.cr` for details.

## Examples

The `examples/` directory has end-to-end samples for most features:

- `examples/hello.cr` — minimal kwarg-only operation
- `examples/positional.cr` — positional + keyword + defaults + `.with`
- `examples/composition.cr` — two/three-op chains, block-only transforms
- `examples/kitchen_sink.cr` — every feature in one file
- `examples/should_fail_*.cr` — compile-error documentation (typo'd kwarg,
  missing required param, bad positional order)

For pipeline-style composition with `step` + hooks, see the spec file
`spec/pipeline_spec.cr` which exercises every feature (named steps,
`on_failure`, `before_step`, empty pipelines, duplicate-step naming,
context merging).

## Development

```bash
script/cr spec               # run the spec suite (62 examples)
bin/ameba src/ spec/ examples/  # lint (clean baseline)
```

## License

MIT. See `LICENSE`.
