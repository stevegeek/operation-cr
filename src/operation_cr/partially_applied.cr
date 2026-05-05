module OperationCr
  # Holds a NamedTuple of arguments bound so far for an Operation class O.
  # The type parameter T encodes which keys are bound, so:
  #   - .with returns a new PartiallyApplied whose T is the merged shape
  #   - .call splats T into O.new, so missing required params are a compile-time error
  class PartiallyApplied(O, T)
    getter bound : T

    def initialize(@bound : T)
    end

    def with(**extra)
      merged = @bound.merge(extra)
      PartiallyApplied(O, typeof(merged)).new(merged)
    end

    def call(**extra)
      O.new(**@bound.merge(extra)).call
    end
  end
end
