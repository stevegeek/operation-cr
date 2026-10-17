module OperationCr
  # A composed pipeline of operations and/or transforms.
  #
  # Generic params:
  #   StartOp  - the head Operation class (a metaclass type). The chain is
  #              invoked via `.call(**args)` whose kwargs are forwarded to
  #              `StartOp.call(**args)`. Type-checking of args therefore happens
  #              at the head's typed initializer (the same as calling StartOp
  #              directly).
  #   R        - StartOp's `perform` return type, i.e. typeof(StartOp.allocate.perform).
  #   FinalT   - the chain's overall result type after all transforms / next ops.
  #   ValueT   - FinalT with a `Success` unwrapped, i.e. the type an
  #              `#and_then` block receives. For a chain that never uses the
  #              opt-in Result module this is just FinalT.
  #
  # The chain holds a single `Proc(R, FinalT)` that represents "everything that
  # happens after StartOp produces its result". Each `.then` extends that proc.
  #
  # ValueT has to be a type parameter rather than a `typeof(...)` computed
  # inside `#and_then`: Crystal rejects `typeof` in a block's type
  # restriction ("can't use 'typeof' here"), and a captured block needs an
  # explicit Proc signature. A class type variable is the only spelling of
  # "the type inside this chain's Success" that a restriction accepts.
  class Chain(StartOp, R, FinalT, ValueT)
    @transform : R -> FinalT

    def initialize(@transform : R -> FinalT)
    end

    # The chain is itself callable like an operation: positional and keyword
    # args are forwarded to StartOp.call. Intermediate ops in the chain remain
    # kwargs-only since the user's transformer block returns a NamedTuple.
    def call(*pos, **args) : FinalT
      head_result = StartOp.call(*pos, **args)
      @transform.call(head_result)
    end

    # Compose with another operation. The block converts the chain's current
    # FinalT into a NamedTuple of args for `next_op.call`. The new chain's
    # FinalT becomes `typeof(NextOp.allocate.perform)`.
    #
    # The block return type is left as `_` because Crystal does not yet
    # allow `NamedTuple` (generic without specific keys) as a block
    # return-type bound — `&block : FinalT -> NamedTuple` errors with
    # "can't use NamedTuple(T) as a block return type yet, use a more
    # specific type". Returning a non-NamedTuple from the block will
    # therefore fail as a deep "no overload matches" inside the splat
    # into `next_op.call(**next_args)` below, rather than a friendly
    # block-boundary error.
    def then(next_op : NextOp.class, &block : FinalT -> _) forall NextOp
      # Snapshot @transform and the captured block into locals before
      # wrapping into the new Proc — the closure would otherwise capture
      # the instance variable by reference, so any later (hypothetical)
      # mutation of @transform on this Chain would silently re-route old
      # downstream chains too. Belt-and-suspenders: Chain currently
      # exposes no @transform setter.
      old_transform = @transform
      transform_block = block
      new_transform = ->(r : R) {
        intermediate = old_transform.call(r)
        next_args = transform_block.call(intermediate)
        NextOp.call(**next_args)
      }
      ::OperationCr::Chain(
        StartOp,
        R,
        typeof(NextOp.allocate.perform),
        typeof(::OperationCr.unwrap_value(NextOp.allocate.perform)),
      ).new(new_transform)
    end

    # Block-only transform (no next op). Block receives the current FinalT and
    # returns the new FinalT.
    def then(&block : FinalT -> NewT) forall NewT
      # See `#then(next_op, &block)` above for the snapshot rationale.
      old_transform = @transform
      transform_block = block
      new_transform = ->(r : R) {
        intermediate = old_transform.call(r)
        transform_block.call(intermediate)
      }
      ::OperationCr::Chain(
        StartOp,
        R,
        NewT,
        typeof(::OperationCr.unwrap_value(::OperationCr.__proc_result_type(transform_block))),
      ).new(new_transform)
    end

    # Result-aware sibling of `#then`. Requires the opt-in Result module
    # (`require "operation_cr/result"`).
    #
    # When the chain's current value is a `Success`, *block* receives the
    # **unwrapped** payload and returns a NamedTuple of kwargs for
    # `next_op`, exactly like `#then`. When it is a `Failure`, the block
    # does not run and that `Failure` becomes the chain's result.
    #
    # `#then` is untouched: it always runs its block, on the wrapped value.
    #
    # On a chain that never carries a Result, `ValueT == FinalT` and the
    # `Failure` guard is statically unreachable, so `#and_then` degrades to
    # `#then` with no widening of the chain's type.
    def and_then(next_op : NextOp.class, &block : ValueT -> _) forall NextOp
      {% if !::OperationCr.has_constant?("Failure") %}
        {% raise "Chain#and_then needs the opt-in Result module. Add: require \"operation_cr/result\" (see src/operation_cr/result.cr)." %}
      {% end %}
      # See `#then(next_op, &block)` above for the snapshot rationale.
      old_transform = @transform
      transform_block = block
      new_transform = ->(r : R) {
        intermediate = old_transform.call(r)
        if intermediate.is_a?(::OperationCr::Failure)
          intermediate
        else
          next_args = transform_block.call(::OperationCr.unwrap_value(intermediate))
          NextOp.call(**next_args)
        end
      }
      ::OperationCr::Chain(
        StartOp,
        R,
        typeof(::OperationCr.__proc_result_type(new_transform)),
        typeof(::OperationCr.unwrap_value(::OperationCr.__proc_result_type(new_transform))),
      ).new(new_transform)
    end

    # Block-only Result-aware transform (no next op). On `Success` the
    # block receives the unwrapped payload; on `Failure` it does not run
    # and the `Failure` is passed through.
    def and_then(&block : ValueT -> NewT) forall NewT
      {% if !::OperationCr.has_constant?("Failure") %}
        {% raise "Chain#and_then needs the opt-in Result module. Add: require \"operation_cr/result\" (see src/operation_cr/result.cr)." %}
      {% end %}
      # See `#then(next_op, &block)` above for the snapshot rationale.
      old_transform = @transform
      transform_block = block
      new_transform = ->(r : R) {
        intermediate = old_transform.call(r)
        if intermediate.is_a?(::OperationCr::Failure)
          intermediate
        else
          transform_block.call(::OperationCr.unwrap_value(intermediate))
        end
      }
      ::OperationCr::Chain(
        StartOp,
        R,
        typeof(::OperationCr.__proc_result_type(new_transform)),
        typeof(::OperationCr.unwrap_value(::OperationCr.__proc_result_type(new_transform))),
      ).new(new_transform)
    end

    # Partial application of the head's positional + keyword args.
    # Mirrors `Operation.with`, including the compile-time kwarg-key
    # validation against the head op's `KW_PARAMS` — a typo'd kwarg here
    # raises a clear "unknown param `…` for StartOp" error at the user's
    # call site rather than surfacing as a deep "no overload matches"
    # when the chain is finally invoked.
    def with(*pos, **args : **A) forall A
      {% for key in A.keys %}
        {% if !StartOp.constant("KW_PARAMS").keys.map(&.id.stringify).includes?(key.id.stringify) %}
          {% raise "unknown param `#{key.id}` for #{StartOp} (head of Chain). Valid params: #{StartOp.constant("KW_PARAMS").keys.map(&.id).join(", ").id}" %}
        {% end %}
      {% end %}
      # `typeof(self)` rather than `self` — `PartiallyAppliedChain`'s
      # first type parameter is the chain's *type*, not its value.
      ::OperationCr::PartiallyAppliedChain(typeof(self), typeof(pos), A).new(self, pos, args)
    end
  end

  # Mirrors `PartiallyApplied` but wraps a `Chain` instead of an Operation class.
  # Holds the chain by reference plus a Tuple of bound positional args and a
  # NamedTuple of bound keyword args. `.call` and `.with` accept and append
  # both, then forward to the chain.
  class PartiallyAppliedChain(C, P, T)
    getter chain : C
    getter bound_pos : P
    getter bound_kw : T

    def initialize(@chain : C, @bound_pos : P, @bound_kw : T)
    end

    def with(*more_pos, **more_kw)
      merged_pos = @bound_pos + more_pos
      merged_kw = @bound_kw.merge(more_kw)
      PartiallyAppliedChain(C, typeof(merged_pos), typeof(merged_kw)).new(@chain, merged_pos, merged_kw)
    end

    def call(*more_pos, **more_kw)
      @chain.call(*(@bound_pos + more_pos), **@bound_kw.merge(more_kw))
    end
  end

  # Reopen Operation to add class-level `.then` macros. Implemented as macros
  # (rather than methods) because Crystal blocks need either an explicit Proc
  # type signature or yield-based call sites; macros let us inline the block
  # body so its parameter type can reference `typeof(SelfClass.allocate.perform)`.
  abstract class Operation
    # `.then(NextOp) { |result| {arg: result, ...} }`
    # The block receives this op's `perform` result and returns a NamedTuple of
    # kwargs for `NextOp.call`.
    macro then(next_op, &block)
      ::OperationCr::Chain(
        {{ @type }},
        typeof({{ @type }}.allocate.perform),
        typeof({{ next_op }}.allocate.perform),
        typeof(::OperationCr.unwrap_value({{ next_op }}.allocate.perform)),
      ).new(
        ->({{ block.args.first.id }} : typeof({{ @type }}.allocate.perform)) {
          %next_args = ({{ block.body }})
          {{ next_op }}.call(**%next_args)
        }
      )
    end

    # `.then { |result| transformed_value }` — block-only transform, no next op.
    macro then(&block)
      %transform = ->({{ block.args.first.id }} : typeof({{ @type }}.allocate.perform)) {
        ({{ block.body }})
      }
      ::OperationCr::Chain(
        {{ @type }},
        typeof({{ @type }}.allocate.perform),
        typeof({{ @type }}.__chain_transform_result(%transform)),
        typeof(::OperationCr.unwrap_value({{ @type }}.__chain_transform_result(%transform))),
      ).new(%transform)
    end

    # `.and_then(NextOp) { |value| {arg: value, ...} }` — starts a chain
    # whose first hop is Result-aware. Requires the opt-in Result module.
    # If this op returned a `Success`, the block receives the unwrapped
    # payload; if it returned a `Failure`, the block does not run and the
    # `Failure` is the chain's result.
    macro and_then(next_op, &block)
      {% if !::OperationCr.has_constant?("Failure") %}
        {% raise "Operation.and_then needs the opt-in Result module. Add: require \"operation_cr/result\" (see src/operation_cr/result.cr)." %}
      {% end %}
      %transform = ->(%head : typeof({{ @type }}.allocate.perform)) {
        if %head.is_a?(::OperationCr::Failure)
          %head
        else
          {{ block.args.first.id }} = ::OperationCr.unwrap_value(%head)
          %next_args = ({{ block.body }})
          {{ next_op }}.call(**%next_args)
        end
      }
      ::OperationCr::Chain(
        {{ @type }},
        typeof({{ @type }}.allocate.perform),
        typeof(::OperationCr.__proc_result_type(%transform)),
        typeof(::OperationCr.unwrap_value(::OperationCr.__proc_result_type(%transform))),
      ).new(%transform)
    end

    # `.and_then { |value| transformed }` — block-only Result-aware
    # transform, no next op.
    macro and_then(&block)
      {% if !::OperationCr.has_constant?("Failure") %}
        {% raise "Operation.and_then needs the opt-in Result module. Add: require \"operation_cr/result\" (see src/operation_cr/result.cr)." %}
      {% end %}
      %transform = ->(%head : typeof({{ @type }}.allocate.perform)) {
        if %head.is_a?(::OperationCr::Failure)
          %head
        else
          {{ block.args.first.id }} = ::OperationCr.unwrap_value(%head)
          ({{ block.body }})
        end
      }
      ::OperationCr::Chain(
        {{ @type }},
        typeof({{ @type }}.allocate.perform),
        typeof(::OperationCr.__proc_result_type(%transform)),
        typeof(::OperationCr.unwrap_value(::OperationCr.__proc_result_type(%transform))),
      ).new(%transform)
    end

    # :nodoc:
    # Type-level helper: applied via `typeof(...)` to learn what a block-only
    # transform produces. The runtime body is never actually executed —
    # `allocate.perform` would crash on a zero-initialized instance — so this
    # method exists purely so the surrounding
    # `typeof(@type.__chain_transform_result(...))` has something to
    # type-check. Public because the `.then` macro expands at the user's
    # call site (outside `Operation`'s scope), so `protected`/`private`
    # would reject the legitimate macro-emitted call. The `__`-prefix and
    # `:nodoc:` tag communicate "do not call directly". Calling at runtime
    # crashes on the `allocate` path.
    def self.__chain_transform_result(t)
      t.call(allocate.perform)
    end
  end
end
