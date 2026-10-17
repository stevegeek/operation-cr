module OperationCr
  # Value plumbing shared by `Pipeline` and `Chain`.
  #
  # These three helpers live in the **core**, not in the opt-in
  # `operation_cr/result` module, and that placement is deliberate.
  # `Pipeline`'s macro emits a call to `step_value` for *every* step, and
  # `Chain` emits `unwrap_value` for every `and_then`. A pipeline whose
  # steps all return plain `NamedTuple`s must still compile in a program
  # that never required `operation_cr/result`, so the identity overloads
  # have to exist unconditionally. The Result-aware overloads are added by
  # `result.cr`, by reopening this module, only when the user opts in.
  #
  # Note that nothing here names `Success` or `Failure`. `unwrap_value`
  # dispatches on the marker method `__operation_cr_unwrap`, which only
  # `Success` and `Failure` define. That is what lets the core compute
  # "the type inside the Success" at compile time while still owning no
  # Result type of its own.
  #
  # All three are public because the `Pipeline` / `.then` / `.and_then`
  # macros expand at the *user's* call site, outside this module's scope.
  # They are plumbing, not API you are expected to call.

  # Returns the `NamedTuple` a pipeline step contributes to the context.
  #
  # Identity for a plain step. `result.cr` adds the `Success(T)` overload
  # that unwraps the payload. The `NamedTuple` restriction (rather than a
  # catch-all) is load-bearing: a step returning a bare value reports "no
  # overload matches" here, naming the step's own return value, instead of
  # failing deep inside `NamedTuple#merge`.
  def self.step_value(result : NamedTuple)
    result
  end

  # Returns the value a `Chain#and_then` block should receive: the payload
  # of a `Success`, or the value itself for anything else.
  #
  # For a chain that never uses Results the `responds_to?` is statically
  # false, so the compiler prunes the branch and the value passes through
  # unchanged — no runtime cost and no type widening.
  def self.unwrap_value(value)
    if value.responds_to?(:__operation_cr_unwrap)
      value.__operation_cr_unwrap
    else
      value
    end
  end

  # :nodoc:
  # Type-level helper: `typeof(OperationCr.__proc_result_type(c))` is the
  # return type of the `Proc` *c*. `Chain` needs this because it must name
  # its own `FinalT` / `ValueT` type arguments from a transform proc it has
  # just built, and Crystal has no `Proc#return_type`. The body exists only
  # so the surrounding `typeof(...)` has something to type-check; calling it
  # at runtime would invoke the proc with a zero-initialized argument, so
  # don't. (`raise` as the body is not an option — the method would then
  # infer as `NoReturn` and the annotation would not save it.)
  def self.__proc_result_type(callable : Proc(A, B)) : B forall A, B
    argument = uninitialized A
    callable.call(argument)
  end
end
