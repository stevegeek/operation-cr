require "../operation_cr"

# Opt-in Result type for `operation_cr`.
#
# ## Why this exists
#
# The core shard has no Result type on purpose: `perform` returns whatever
# you want, and a genuine error raises. That is the right default for the
# unexpected — a dead database, a bug — and it stays the default.
#
# It is the wrong shape for the *expected* failures of a business
# operation: invalid input, a card declined, a slot already booked. Those
# are not exceptional, they are one of the two normal answers, and an
# exception hides them from the type system. The caller cannot see them in
# the signature and the compiler cannot make anyone handle them.
#
# ## Why it is opt-in
#
# A Result type is a whole-codebase decision, so `src/operation_cr.cr`
# does **not** require this file. The core stays Result-free; you buy in
# per project with an explicit require:
#
# ```
# require "operation_cr"
# require "operation_cr/result"
# ```
#
# Requiring it also teaches `Chain#and_then` and `Pipeline` to
# short-circuit on `Failure`. Code that never requires it is completely
# unaffected, down to its inferred return types.
#
# ## The exhaustiveness guarantee
#
# The type is the plain union `Success(T) | Failure` — there is no
# `Result(T)` name (Crystal has no generic aliases; `alias Result(T) = ...`
# does not parse) and no abstract parent struct (that compiles, but the
# static type becomes the parent and `case/in` stops being exhaustive).
#
# The union is the entire point. `case/in` over it is exhaustive, so:
#
# ```
# case result
# in OperationCr::Success then result.value # typed T. Not T?. No unwrap, no raise.
# in OperationCr::Failure then result.errors
# end
# ```
#
# In the `Success` branch the value is statically `T`: no nil, no `value!`,
# no exception to catch. And omitting the `Failure` branch is a compile
# error — "case is not exhaustive. Missing types: OperationCr::Failure" —
# so a caller cannot forget the failure path. An `ok?` / `value!` struct
# gives you neither of those; that is the whole reason to prefer this.
#
# ## Writing the type down
#
# Because there is no `Result(T)` name, write the union, or make a local
# non-generic alias per call site:
#
# ```
# alias CreateUserResult = OperationCr::Success(User) | OperationCr::Failure
#
# class CreateUser < OperationCr::Operation
#   param email : String
#
#   def perform : CreateUserResult
#     return OperationCr::Failure.new(:invalid, "email") unless email.includes?('@')
#     OperationCr::Success.new(User.new(email))
#   end
# end
# ```
module OperationCr
  # One failure reason. `code` is the machine-readable discriminator you
  # branch and translate on; `field` names the input it belongs to (nil for
  # whole-operation failures); `detail` is optional human context.
  record Error, code : Symbol, field : String? = nil, detail : String? = nil

  # The success half of `Success(T) | Failure`. Carries a payload typed `T`.
  struct Success(T)
    getter value : T

    def initialize(@value : T)
    end

    def ok? : Bool
      true
    end

    # Runs *block* with the unwrapped value and returns its Result. This is
    # the success half of short-circuiting: on `Failure` the mirror-image
    # method returns self without running the block.
    def and_then(&block : T -> (Success(U) | Failure)) : Success(U) | Failure forall U
      block.call(@value)
    end

    # Transforms the payload, keeping it wrapped. The declared return type
    # stays the full union so a chain of `map`s does not narrow to
    # `Success` and lose exhaustiveness at the end.
    def map(&block : T -> U) : Success(U) | Failure forall U
      Success(U).new(block.call(@value))
    end

    # :nodoc:
    # Marker method `OperationCr.unwrap_value` dispatches on. See
    # `step_value.cr` for why the core detects Results structurally rather
    # than by naming this type.
    def __operation_cr_unwrap : T
      @value
    end
  end

  # The failure half of `Success(T) | Failure`. Deliberately **not**
  # generic: it carries no phantom payload type, so failures from
  # differently-typed operations are the same type and combine freely.
  struct Failure
    # Every reason this failed, in order.
    #
    # A `Failure` is a value, so it must not share one mutable array with
    # its copies or with whoever built it. Both routes into `@errors` are
    # closed: the constructor copies the array it is given, and this getter
    # copies the array it returns. Mutating what you get back changes
    # nothing — build a new `Failure`, or combine with `#+`.
    def errors : Array(Error)
      @errors.dup
    end

    # The name of the pipeline step that produced this failure, or nil for
    # a failure that never went through a `Pipeline`.
    #
    # `Pipeline` tags every `Failure` a step returns before it short-circuits,
    # so the caller can tell two steps returning the same code apart — and
    # can tell which pipeline position an operation reused in several
    # pipelines failed at. Without the tag the only answer is the one
    # `on_step_failure` gives you, and only if you defined it.
    getter step : Symbol?

    def initialize(errors : Array(Error), @step : Symbol? = nil)
      @errors = errors.dup
    end

    def initialize(code : Symbol, field : String? = nil, detail : String? = nil, @step : Symbol? = nil)
      @errors = [Error.new(code, field, detail)]
    end

    # Returns a copy tagged with *step_name*, or self if this failure is
    # already tagged.
    #
    # The first tag wins so that the innermost origin survives: a `Failure`
    # a nested pipeline already attributed keeps that attribution when the
    # outer pipeline short-circuits on it.
    def at_step(step_name : Symbol) : Failure
      return self if @step
      Failure.new(@errors, step_name)
    end

    def ok? : Bool
      false
    end

    # Returns self; *block* never runs. This is the short-circuit.
    def and_then(&) : Failure
      self
    end

    # Returns self; *block* never runs.
    def map(&) : Failure
      self
    end

    # The first reason this failed. Raises `IndexError` on a `Failure`
    # constructed with an empty error array.
    def first_error : Error
      @errors.first
    end

    # The codes of every error, in order — what you branch or translate on.
    def codes : Array(Symbol)
      @errors.map(&.code)
    end

    # Combines two failures, concatenating their errors. Useful when
    # validating several inputs and reporting all of them at once.
    #
    # The combined failure keeps the left-hand `step` tag, falling back to
    # the right-hand one when the left is untagged.
    def +(other : Failure) : Failure
      Failure.new(@errors + other.@errors, @step || other.@step)
    end

    # :nodoc:
    # Present only so `OperationCr.unwrap_value` narrows a
    # `Success(T) | Failure` to `T` rather than `T | Failure` at the type
    # level. `NoReturn` removes this branch from the inferred union. The
    # guard in `Chain#and_then` / `Pipeline` means it is never reached.
    def __operation_cr_unwrap : NoReturn
      raise "OperationCr::Failure carries no value; guard with `is_a?(OperationCr::Failure)` first"
    end
  end

  # Result-aware overload of the core's pipeline plumbing: a step returning
  # `Success(NamedTuple)` merges the unwrapped NamedTuple. Only the
  # `Success` case needs an overload — `Pipeline` returns early on
  # `Failure`, so `step_value` never sees one.
  def self.step_value(result : Success(T)) : T forall T
    result.value
  end
end
