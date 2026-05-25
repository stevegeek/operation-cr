module OperationCr
  # Currying for Operations: consume one arg at a time, returning a new
  # `Curried` until every required param is bound, then run the operation.
  #
  # Operation:
  #
  #     class Add < OperationCr::Operation
  #       positional_param a : Int32
  #       positional_param b : Int32
  #       def perform; a + b; end
  #     end
  #
  # Curry one arg at a time:
  #
  #     curry  = Add.curry             # Curried(Add, Tuple(), NamedTuple())
  #     step   = curry.call(2)         # => Curried(Add, ...) | Int32
  #     result = step.as(Curried).call(3)   # => 5
  #
  # The next arg goes positional first (until every required positional
  # param is bound), then keyword in declaration order. `.call(arg)`
  # returns either a new `Curried` or — if all required params are now
  # bound — the operation's result. Callers handle the union via
  # `is_a?(Curried)` / `.as(Curried)`.
  #
  # Note vs Ruby's typed_operation: Crystal's static type system means
  # the bound-args shape (P, T) is part of the type, so each step's
  # Curried is a different concrete type. The user-facing union is the
  # price of strongly typed currying — there's no way to say "this is
  # a Curried, but I don't know what shape" without losing type safety.
  class Curried(O, P, T)
    @bound_pos : P
    @bound_kw : T

    # Build a fresh Curried for `op_class` with no args bound yet.
    def self.fresh(op_class : O.class) : ::OperationCr::Curried(O, Tuple(), NamedTuple())
      ::OperationCr::Curried(O, Tuple(), NamedTuple()).new(Tuple.new, NamedTuple.new)
    end

    def initialize(@bound_pos : P, @bound_kw : T)
    end

    # All required params already bound — calling `.call` with no args
    # would invoke the operation.
    def prepared? : Bool
      bound_kw_keys = @bound_kw.keys.map(&.to_s)
      O.required_positional_params.size <= @bound_pos.size &&
        O.required_keyword_params.all? { |k| bound_kw_keys.includes?(k.to_s) }
    end

    # Compile-time guard: emits `prepared_body` if O's required positional
    # + keyword params are statically satisfied by the bound (P, T) shape,
    # otherwise emits `unprepared_body`. Centralised here so the two call
    # sites that need to branch on it (`#call` no-arg and
    # `#invoke_if_prepared`) stay in sync.
    private macro emit_if_prepared(prepared_body, unprepared_body)
      {% if (
              O.constant("POSITIONAL_PARAMS").keys.select { |k| !O.constant("POSITIONAL_PARAMS")[k][:has_default] }.size <= P.type_vars.size
            ) && (
              O.constant("KW_PARAMS").keys.select { |k| !O.constant("KW_PARAMS")[k][:has_default] }.all? do |k|
                T.keys.map(&.id.stringify).includes?(k.id.stringify)
              end
            ) %}
        {{ prepared_body }}
      {% else %}
        {{ unprepared_body }}
      {% end %}
    end

    # Run the operation with the args bound so far. The macro guard
    # only emits the actual invocation when the bound (P, T) shape
    # statically satisfies O's `.new` signature — for un-prepared
    # Curried instantiations, calling `.call` raises at runtime instead
    # of failing compilation in unrelated code paths.
    def call
      emit_if_prepared(
        O.new(*@bound_pos, **@bound_kw).call,
        raise ArgumentError.new("Curried(#{O}) is not prepared yet — bind more args via .call(arg) first")
      )
    end

    # Bind one more arg (positional or keyword, decided automatically by
    # the operation's declared params) and either return a new Curried
    # or — if all required params are now bound — the operation's result.
    def call(arg)
      next_curried =
        if @bound_pos.size < O.required_positional_params.size
          new_pos = @bound_pos + Tuple.new(arg)
          ::OperationCr::Curried(O, typeof(new_pos), T).new(new_pos, @bound_kw)
        else
          key = next_keyword_param
          if key.nil?
            raise ArgumentError.new("No more parameters available to curry into #{O}")
          end
          apply_keyword(key, arg)
        end

      # `prepared?` is a runtime check; we want to invoke when prepared.
      # The macro below splits this into compile-time-distinct branches
      # so the no-arg `O.new` call only appears in branches where (P, T)
      # actually fit O — otherwise Crystal rejects the whole method.
      next_curried.invoke_if_prepared
    end

    # Compile-time-checked dispatch: emits the no-arg `.call` invocation
    # only when the bound (P, T) shape matches O's required params. When
    # it doesn't, just returns self so the user can add another arg.
    # See `emit_if_prepared` macro above.
    protected def invoke_if_prepared
      emit_if_prepared(
        O.new(*@bound_pos, **@bound_kw).call,
        self
      )
    end

    private def next_keyword_param : Symbol?
      bound = @bound_kw.keys.to_a
      O.required_keyword_params.find { |k| !bound.includes?(k) }
    end

    # NamedTuple is type-indexed: keys are part of the type. We can't
    # merge a runtime Symbol; we have to dispatch on the operation's
    # compile-time-known KW_PARAMS list.
    private def apply_keyword(key : Symbol, value)
      {% begin %}
        case key
        {% for name in O.constant("KW_PARAMS").keys %}
        when {{ name }}
          new_kw = @bound_kw.merge({{ name.id }}: value)
          ::OperationCr::Curried(O, P, typeof(new_kw)).new(@bound_pos, new_kw)
        {% end %}
        else
          raise ArgumentError.new("Unknown keyword param #{key} for #{O}")
        end
      {% end %}
    end
  end

  abstract class Operation
    # Returns a Curried wrapper bound to no args yet. Each subsequent
    # `.call(arg)` consumes one arg and either returns a new Curried or
    # the operation's result if all required params are bound.
    def self.curry
      ::OperationCr::Curried.fresh(self)
    end
  end
end
