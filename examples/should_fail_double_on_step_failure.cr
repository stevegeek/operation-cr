# script/check-compile-errors asserts this file fails to compile with:
# expect-error: DoubleHandlerPipeline: on_step_failure may only be defined once per pipeline.
#
require "../src/operation_cr"
require "../src/operation_cr/result"

alias StepResult = OperationCr::Success(NamedTuple(checked: Bool)) | OperationCr::Failure

class CheckIt < OperationCr::Operation
  param value : Int32

  def perform : StepResult
    return OperationCr::Failure.new(:negative, "value") if value < 0
    OperationCr::Success.new({checked: true})
  end
end

# Two `on_step_failure` blocks in one pipeline -- should produce a compile
# error naming the pipeline, because the second definition would silently
# overwrite the first. Same guard as duplicate `on_failure` / `before_step`.
class DoubleHandlerPipeline < OperationCr::Pipeline
  step CheckIt

  on_step_failure do |failure, step_name|
    {first: failure.codes, at: step_name}
  end

  on_step_failure do |failure, step_name|
    {second: failure.codes, at: step_name}
  end
end
