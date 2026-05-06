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

    # True when every required param of `O` has been bound — i.e. calling
    # `.call` with no further args would succeed. Used by Curried to
    # decide between consuming another arg vs invoking the operation.
    def prepared? : Bool
      bound_kw_keys = @bound_kw.keys.map(&.to_s)
      O.required_positional_params.size <= @bound_pos.size &&
        O.required_keyword_params.all? { |k| bound_kw_keys.includes?(k.to_s) }
    end

    # Number of bound positional args, exposed for Curried which uses it
    # to decide whether the next arg is positional or keyword.
    def positional_args_size : Int32
      @bound_pos.size
    end

    # Bound keyword arg keys (as Symbols). Curried uses this to find the
    # next required keyword param not yet bound.
    def bound_keyword_keys : Array(Symbol)
      @bound_kw.keys.to_a
    end
  end
end
