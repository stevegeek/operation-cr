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
  #
  # The chain holds a single `Proc(R, FinalT)` that represents "everything that
  # happens after StartOp produces its result". Each `.then` extends that proc.
  class Chain(StartOp, R, FinalT)
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
      ::OperationCr::Chain(StartOp, R, typeof(NextOp.allocate.perform)).new(new_transform)
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
      ::OperationCr::Chain(StartOp, R, NewT).new(new_transform)
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
