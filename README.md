# operation_cr

A small Crystal shard for building **typed command objects** — classes with a
typed constructor (from `param` / `positional_param` macros) and a single
`perform` method whose return value is returned verbatim from `.call`.

Around that core sit four extensions:

- **`.with(...)`** — partial application that preserves types and validates
  kwarg keys at compile time (typo → compile error at *your* call site).
- **`.then(NextOp) { |r| {...} }`** — linear composition into a `Chain`.
- **`.curry`** — one-arg-at-a-time application.
- **`.explain(...)`** — STDOUT (or any IO) tracer that prints an ASCII tree
  of nested operation calls with timings.

## What this is NOT

`operation_cr` is **not** a Trailblazer / Interactor / dry-monads port. If
you're looking for those features, this shard does not have them and is not
trying to:

- No `Result(T)` / `Success` / `Failure` type. `perform` returns whatever
  you want; if it raises, the exception propagates uncaught.
- No `halt` / `abort` semantics. The only way to stop a `Chain` mid-flight
  is `raise` from a step.
- No transactions / around hooks. `before_execute` / `after_execute` are
  pre/post-only — there's no `around { |&| db.transaction { yield } }`.
- No step DSL. The chain is built by Crystal-level `.then` calls, not a
  declarative `step :validate, :persist` list.
- No exception swallowing — by design. Exceptions propagate.

What you get is a typed-constructor + partial-application + linear-pipeline
+ curry shard with a focus on **compile-time error messages at the call site**.

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

The `examples/` directory has end-to-end samples for every feature:

- `examples/hello.cr` — minimal kwarg-only operation
- `examples/positional.cr` — positional + keyword + defaults + `.with`
- `examples/composition.cr` — two/three-op chains, block-only transforms
- `examples/kitchen_sink.cr` — every feature in one file
- `examples/should_fail_*.cr` — compile-error documentation (typo'd kwarg,
  missing required param, bad positional order)

## Development

```bash
script/cr spec               # run the spec suite (47+ examples)
bin/ameba src/ spec/ examples/  # lint (clean baseline)
```

## License

MIT. See `LICENSE`.
