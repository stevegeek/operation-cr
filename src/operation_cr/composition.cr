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
    def then(next_op : NextOp.class, &block : FinalT -> _) forall NextOp
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
      old_transform = @transform
      transform_block = block
      new_transform = ->(r : R) {
        intermediate = old_transform.call(r)
        transform_block.call(intermediate)
      }
      ::OperationCr::Chain(StartOp, R, NewT).new(new_transform)
    end

    # Partial application of the head's positional + keyword args.
    # Mirrors `Operation.with`.
    def with(*pos, **args)
      ::OperationCr::PartiallyAppliedChain(self, typeof(pos), typeof(args)).new(self, pos, args)
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
        {{@type}},
        typeof({{@type}}.allocate.perform),
        typeof({{next_op}}.allocate.perform),
      ).new(
        ->({{block.args.first.id}} : typeof({{@type}}.allocate.perform)) {
          %next_args = ({{block.body}})
          {{next_op}}.call(**%next_args)
        }
      )
    end

    # `.then { |result| transformed_value }` — block-only transform, no next op.
    macro then(&block)
      %transform = ->({{block.args.first.id}} : typeof({{@type}}.allocate.perform)) {
        ({{block.body}})
      }
      ::OperationCr::Chain(
        {{@type}},
        typeof({{@type}}.allocate.perform),
        typeof({{@type}}.__chain_transform_result(%transform)),
      ).new(%transform)
    end

    # Type-level helper: applied via `typeof(...)` to learn what a block-only
    # transform produces. Never actually invoked at runtime.
    def self.__chain_transform_result(t)
      t.call(self.allocate.perform)
    end
  end
end
