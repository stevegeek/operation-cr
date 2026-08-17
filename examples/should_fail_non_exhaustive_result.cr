require "../src/operation_cr"
require "../src/operation_cr/result"

alias ParseResult = OperationCr::Success(Int32) | OperationCr::Failure

class ParseInt < OperationCr::Operation
  param raw : String

  def perform : ParseResult
    parsed = raw.to_i?
    return OperationCr::Failure.new(:not_a_number, "raw") if parsed.nil?
    OperationCr::Success.new(parsed)
  end
end

# The whole reason `Success(T) | Failure` is a plain union rather than an
# `ok?`/`value!` struct: forgetting the failure branch is a compile error,
# "case is not exhaustive. Missing types: OperationCr::Failure".
#
# Add `in OperationCr::Failure then ...` and this file compiles. Note that
# in the Success branch `result.value` is statically Int32 -- no nil check,
# no unwrap, no rescue.
result = ParseInt.call(raw: "42")

case result
in OperationCr::Success
  puts result.value + 1
end
