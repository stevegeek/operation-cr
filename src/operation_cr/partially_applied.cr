module OperationCr
  # Holds positional and keyword arguments bound so far for an Operation class O.
  #
  # Type parameters:
  #   - P: Tuple type capturing the bound positional args (in declaration order)
  #   - T: NamedTuple type capturing which keyword keys are bound
  #
  # Both .with and .call splat into O.new, so missing required params (or wrong
  # types) surface as compile-time errors via Crystal's normal arg checking.
  class PartiallyApplied(O, P, T)
    getter bound_pos : P
    getter bound_kw : T

    def initialize(@bound_pos : P, @bound_kw : T)
    end

    def with(*more_pos, **more_kw)
      merged_pos = @bound_pos + more_pos
      merged_kw = @bound_kw.merge(more_kw)
      PartiallyApplied(O, typeof(merged_pos), typeof(merged_kw)).new(merged_pos, merged_kw)
    end

    def call(*more_pos, **more_kw)
      O.new(*(@bound_pos + more_pos), **@bound_kw.merge(more_kw)).call
    end
  end
end
