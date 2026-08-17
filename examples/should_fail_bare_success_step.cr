require "../src/operation_cr"
require "../src/operation_cr/result"

alias DoubledResult = OperationCr::Success(Int32) | OperationCr::Failure

class Seed < OperationCr::Operation
  param a : Int32

  def perform : NamedTuple(a: Int32)
    {a: a}
  end
end

class Double < OperationCr::Operation
  param a : Int32

  # A pipeline step must contribute a NamedTuple to the context. A bare
  # value is as wrong inside a `Success` as it is on its own.
  def perform : DoubledResult
    OperationCr::Success.new(a * 2)
  end
end

# The error names `OperationCr.step_value` and the step's own return value
# -- "expected argument #1 to 'OperationCr.step_value' to be NamedTuple(T)
# or OperationCr::Success(NamedTuple(T)), not OperationCr::Success(Int32)"
# -- rather than failing deep inside `NamedTuple#merge`. Same message shape
# as a plain step returning a bare `Int32`.
#
# Fix by wrapping at the operation boundary: `Success.new({doubled: a * 2})`.
class DoublePipeline < OperationCr::Pipeline
  step Seed
  step Double
end

DoublePipeline.call(a: 1)
