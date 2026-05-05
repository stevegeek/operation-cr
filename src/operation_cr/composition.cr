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

    # The chain is itself callable like an operation: kwargs go to StartOp.call.
    def call(**args) : FinalT
      head_result = StartOp.call(**args)
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

    # Partial application of the head's kwargs. Mirrors `Operation.with`.
    def with(**args)
      ::OperationCr::PartiallyAppliedChain(self, typeof(args)).new(self, args)
    end
  end

  # Mirrors `PartiallyApplied` but wraps a `Chain` instead of an Operation class.
  # The chain is held by reference; `.call(**extra)` merges the bound NamedTuple
  # with any extras and forwards to the chain.
  class PartiallyAppliedChain(C, T)
    getter chain : C
    getter bound : T

    def initialize(@chain : C, @bound : T)
    end

    def with(**extra)
      merged = @bound.merge(extra)
      PartiallyAppliedChain(C, typeof(merged)).new(@chain, merged)
    end

    def call(**extra)
      @chain.call(**@bound.merge(extra))
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
