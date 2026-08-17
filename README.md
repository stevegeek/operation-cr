# operation_cr

A small Crystal shard for building **typed command objects** — classes with a
typed constructor (from `param` / `positional_param` macros) and a single
`perform` method whose return value is returned verbatim from `.call`.

Around that core sit five extensions:

- **`.with(...)`** — partial application that preserves types and validates
  kwarg keys at compile time (typo → compile error at *your* call site).
- **`.then(NextOp) { |r| {...} }`** — linear composition into a `Chain`.
- **`OperationCr::Pipeline`** — declarative `step Op` DSL with auto-merging
  NamedTuple context, `on_failure`, `on_step_failure` and `before_step` hooks.
- **`.curry`** — one-arg-at-a-time application.
- **`.explain(...)`** — STDOUT (or any IO) tracer that prints an ASCII tree
  of nested operation calls with timings.

Plus one **opt-in** module — `require "operation_cr/result"` — that adds a
`Success(T) | Failure` type, `Chain#and_then`, and `Pipeline`
short-circuiting. See [Results (opt-in)](#results-opt-in).

## What this is NOT

`operation_cr` is **not** a Trailblazer / Interactor / dry-monads port. If
you're looking for those features, this shard does not have them and is not
trying to:

- **The core has no `Result(T)` / `Success` / `Failure` type.** `perform`
  returns whatever you want; if it raises, the exception propagates
  uncaught. Since 0.3.0 there *is* a Result type, but it sits outside the
  core and you opt in per project with an explicit require:
  `src/operation_cr.cr` does not require it, and a program that never
  requires it is unaffected down to its inferred return types. See
  [Results (opt-in)](#results-opt-in). Even opted in, what you get is one
  union type plus `and_then` / `map` — not a monad library. No `Maybe`, no
  do-notation, no transformers.
- No `halt` / `abort` semantics. Without the Result module, the only way to
  stop a `Chain` or `Pipeline` mid-flight is `raise` from a step. With it,
  returning a `Failure` stops a `Pipeline` and skips the rest of an
  `and_then` chain — but that is a value a step returns, not a control-flow
  keyword you can call from anywhere.
- No transactions / around hooks. `before_execute` / `after_execute` are
  pre/post-only — there's no `around { |&| db.transaction { yield } }`.
  (A `Pipeline` does have a `before_step` hook for per-step side effects,
  but no around-hook.)
- No exception swallowing — by design. Exceptions propagate or are caught
  by an explicit `on_failure` handler in a `Pipeline`. A returned `Failure`
  is not an exception and has its own handler, `on_step_failure`; the two
  are never conflated.

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

With the opt-in Result module there is also `.and_then`, which unwraps a
`Success` before calling the block and skips the block entirely on a
`Failure` — see [Results (opt-in)](#results-opt-in). `.then` is unchanged:
it always runs its block, on whatever the previous step returned.

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

For failures that aren't exceptional — invalid input, a declined card —
the opt-in Result module lets a step *return* a `Failure`, which
short-circuits the pipeline and can be handled by `on_step_failure`. See
[Results (opt-in)](#results-opt-in).

**Step naming.** `step Op` derives the step name from the operation's
class basename (`Publish::Operations::CloneRepo` → `:clone_repo`). Use
`step :name, Op` for an explicit name passed to `on_failure` / `before_step`.

**Compile-time guards:**

- Subclassing a `Pipeline` subclass is rejected — the per-subclass step
  accumulator wouldn't carry parent steps and hooks would silently drop.
  Subclass `OperationCr::Pipeline` directly.
- Step operations using `positional_param` are rejected — pipelines pass
  kwargs only.
- Duplicate `on_failure`, `on_step_failure` or `before_step` definitions in
  one Pipeline subclass are rejected (would silently overwrite).

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

## Results (opt-in)

New in 0.3.0. **The core still has no Result type.** `src/operation_cr.cr`
does not require this module; you buy in per project:

```crystal
require "operation_cr"
require "operation_cr/result"
```

Requiring it adds `OperationCr::Success(T)`, `OperationCr::Failure` and
`OperationCr::Error`, adds `and_then` to `Chain`, and teaches `Pipeline` to
short-circuit. A program that never requires it behaves exactly as it did
in 0.2.0, down to its inferred return types.

**Why have one at all.** Raising is the right default for the unexpected —
a dead database, a bug — and it stays the default. It is the wrong shape
for the *expected* failures of a business operation: invalid input, a card
declined, a slot already booked. Those are one of the two normal answers,
and an exception hides them from the type system.

### There is no `Result(T)` type name

Crystal has no generic aliases. `alias Result(T) = Success(T) | Failure`
does not parse ("expecting token '=', not '('"). So the type is written as
the union, or aliased per call site:

```crystal
alias CreateUserResult = OperationCr::Success(User) | OperationCr::Failure

class CreateUser < OperationCr::Operation
  param email : String

  def perform : CreateUserResult
    return OperationCr::Failure.new(:invalid, "email") unless email.includes?('@')
    OperationCr::Success.new(User.new(email))
  end
end
```

An abstract-struct hierarchy (`abstract struct Result(T)` with `Success` /
`Failure` subclasses) was tried and rejected: it compiles, but the static
type becomes the abstract parent, `case/in` reports "case is not
exhaustive. Missing types: Result(Int32)", and you get a shape that looks
like a monad while giving none of the guarantee. `Failure` is deliberately
**not** generic — it carries no phantom payload type, so failures from
differently-typed operations are the same type and combine freely.

### The exhaustiveness guarantee

The union is the whole point:

```crystal
case result
in OperationCr::Success
  # `value` is statically User. Not User?. No unwrap, no raise, no rescue.
  send_welcome(result.value)
in OperationCr::Failure
  render_errors(result.errors)
end
```

Delete the `Failure` branch and it is a compile error — "case is not
exhaustive. Missing types: OperationCr::Failure" (see
`examples/should_fail_non_exhaustive_result.cr`). An `ok?` / `value!`
struct gives you neither the typed payload nor the forced branch; that is
the reason to prefer this.

### API

`OperationCr::Error` — `record Error, code : Symbol, field : String? = nil,
detail : String? = nil`.

`OperationCr::Success(T)`

| Method | Notes |
| --- | --- |
| `#value : T` | The payload. |
| `#ok? : Bool` | `true`. |
| `#and_then { \|value\| ... }` | Runs the block on the unwrapped value; the block returns a Result. |
| `#map { \|value\| ... }` | Transforms the payload, keeps it wrapped. |

`OperationCr::Failure`

| Method | Notes |
| --- | --- |
| `.new(errors : Array(Error))` | Copies the array. |
| `.new(code : Symbol, field : String? = nil, detail : String? = nil)` | Single-error shorthand. |
| `#errors : Array(Error)` | A copy. `Failure` is a value type and shares no mutable state with its copies, so mutating what you get back changes nothing. |
| `#ok? : Bool` | `false`. |
| `#and_then { ... }` | Returns self. **The block never runs.** |
| `#map { ... }` | Returns self. The block never runs. |
| `#first_error : Error` | Raises `Enumerable::EmptyError` if built with an empty array. |
| `#codes : Array(Symbol)` | Every error's code, in order. |
| `#step : Symbol?` | The pipeline step that produced it; nil for a failure built outside a pipeline. |
| `#at_step(step_name : Symbol) : Failure` | A copy tagged with that step. Already-tagged failures are returned unchanged, so the innermost origin survives. |
| `#+(other : Failure) : Failure` | Concatenates errors — report all bad inputs at once. |

```crystal
result = OperationCr::Success.new(4)
  .and_then { |n| OperationCr::Success.new(n * 2).as(MyResult) }
  .and_then { |n| OperationCr::Failure.new(:too_big, "n").as(MyResult) }
  .and_then { |n| OperationCr::Success.new(n + 1000).as(MyResult) } # never runs

result.as(OperationCr::Failure).codes # => [:too_big]
```

### `Chain#and_then`

`.and_then` is the Result-aware sibling of `.then`. On a `Success` the
block receives the **unwrapped** payload; on a `Failure` the block does not
run and the `Failure` becomes the chain's result. `.then`'s semantics are
untouched — it always runs its block, on the wrapped value.

```crystal
chain = ParseInt.and_then(Halve) { |n| {n: n} }

chain.call(raw: "10")   # => Success(5)
chain.call(raw: "oops") # => Failure(:not_a_number) — Halve never runs
```

Both forms exist (`.and_then(NextOp) { |value| {kwargs} }` and the
block-only `.and_then { |value| ... }`), as a class-level macro on
`Operation` to start a chain and as a method on `Chain` to extend one.
Plain and Result steps mix freely:

```crystal
Double.then(ParseInt) { |x| {raw: x.to_s} }.and_then(Describe) { |n| {n: n} }
# call type: String | OperationCr::Failure
```

On a chain that never carries a Result, `.and_then` degrades to `.then`
with no `Failure` in the inferred type.

### `Pipeline` short-circuiting

A step may return `Success(NamedTuple) | Failure` instead of a plain
`NamedTuple`. The unwrapped NamedTuple of a `Success` merges into the
context as usual; a `Failure` stops the pipeline immediately and becomes
its return value. Later steps do not run.

```crystal
class OrderPipeline < OperationCr::Pipeline
  step ValidateOrder   # returns Success({validated: true}) | Failure
  step FetchPrice      # returns Success({unit_price_cents: …}) | Failure
  step ComputeTotal    # plain NamedTuple — unchanged, cannot fail

  on_step_failure do |failure, step_name|
    Log.warn { "#{step_name}: #{failure.codes.inspect}" }
    {ok: false, failed_at: step_name, codes: failure.codes}
  end
end
```

`on_step_failure` receives the `Failure` and the failing step's name
(Symbol); its return value becomes the pipeline's return value. Without
it, the pipeline returns the `Failure` and the call type is
`context | OperationCr::Failure` — which the caller then has to handle
exhaustively.

Either way the `Failure` knows where it came from: the pipeline tags it
with the failing step's name before it short-circuits, so "which step
produced `:not_found`?" is answerable without a handler.

```crystal
result = OrderPipeline.call(quantity: 0, product_id: 2)
result.as(OperationCr::Failure).step  # => :validate_quantity
```

A `Failure` that is already tagged keeps its tag, so when a pipeline step
runs a nested pipeline the innermost origin survives.

The handler runs **outside** the `begin`/`rescue` that `on_failure`
protects. An exception it raises reaches the caller as itself, rather than
being caught by `on_failure` and reported as the step raising.

It is **separate from `on_failure`** on purpose. `on_failure` is for
exceptions a step raised; `on_step_failure` is for a `Failure` a step
returned. They carry different payloads and mean different things, so
routing one into the other would need a fake exception and would make both
handlers lie about what they receive. A pipeline may define both. Defining
either twice is a compile error (see
`examples/should_fail_double_on_step_failure.cr`).

**Short-circuiting is automatic — there is no opt-in macro and no cost to
pipelines that don't use it.** The guard is emitted for every step, and
Crystal prunes it where it is statically unreachable, so a pipeline of
plain steps keeps its exact 0.2.0 return type:

```crystal
typeof(PlainPipeline.call(a: 1))  # => NamedTuple(a: Int32, b: Int32, c: Int32)
typeof(ResultPipeline.call(a: 1)) # => NamedTuple(…) | OperationCr::Failure
```

Both are asserted in `spec/pipeline_result_spec.cr` rather than left to
inspection.

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

The `examples/` directory has end-to-end samples for every feature:

- `examples/hello.cr` — minimal kwarg-only operation
- `examples/positional.cr` — positional + keyword + defaults + `.with`
- `examples/composition.cr` — two/three-op chains, block-only transforms
- `examples/pipeline.cr` — declarative `Pipeline` with `step`, `before_step`,
  `on_failure`, named steps, context merging, and unit-testable ops
- `examples/result_pipeline.cr` — the same order flow with the opt-in Result
  module: failing steps, short-circuiting, `on_step_failure`, exhaustive
  handling at the call site, and `Chain#and_then`
- `examples/kitchen_sink.cr` — every feature in one file
- `examples/should_fail_*.cr` — compile-error documentation (typo'd kwarg,
  missing required param, bad positional order, non-exhaustive `case/in`
  over a Result, duplicate `on_step_failure`, a step returning a bare value
  inside a `Success`)

## Development

```bash
script/cr spec               # run the spec suite (106 examples)
bin/ameba src/ spec/ examples/  # lint (clean baseline)
```

The `examples/should_fail_*.cr` files are compile-error documentation and
are checked by hand:

```bash
script/cr build --no-codegen examples/should_fail_typo.cr  # must fail
```

## License

MIT. See `LICENSE`.
