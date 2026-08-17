require "./spec_helper"
require "../src/operation_cr/result"

alias PipelineResultSpecValidated = OperationCr::Success(NamedTuple(validated: Bool)) | OperationCr::Failure
alias PipelineResultSpecPriced = OperationCr::Success(NamedTuple(unit_price: Int32)) | OperationCr::Failure

class PipelineResultSpec::ValidateQuantity < OperationCr::Operation
  class_property calls : Int32 = 0

  param quantity : Int32

  def perform : PipelineResultSpecValidated
    @@calls += 1
    return OperationCr::Failure.new(:not_positive, "quantity", "got #{quantity}") unless quantity > 0
    OperationCr::Success.new({validated: true})
  end
end

class PipelineResultSpec::FetchPrice < OperationCr::Operation
  class_property calls : Int32 = 0

  param product_id : Int32

  def perform : PipelineResultSpecPriced
    @@calls += 1
    return OperationCr::Failure.new(:unknown_product, "product_id") if product_id < 1
    OperationCr::Success.new({unit_price: product_id * 100})
  end
end

class PipelineResultSpec::ComputeTotal < OperationCr::Operation
  class_property calls : Int32 = 0

  param quantity : Int32
  param unit_price : Int32

  def perform : NamedTuple(total: Int32)
    @@calls += 1
    {total: quantity * unit_price}
  end
end

class PipelineResultSpec::Explodes < OperationCr::Operation
  param quantity : Int32

  def perform : NamedTuple(never: Bool)
    raise "boom from Explodes"
  end
end

# Plain-NamedTuple operations: this pipeline must be completely unaffected
# by the Result module being loaded elsewhere in the program.
class PipelineResultSpec::PlainA < OperationCr::Operation
  param a : Int32

  def perform : NamedTuple(b: Int32)
    {b: a + 1}
  end
end

class PipelineResultSpec::PlainB < OperationCr::Operation
  param b : Int32

  def perform : NamedTuple(c: Int32)
    {c: b * 10}
  end
end

class PipelineResultSpec::OrderPipeline < OperationCr::Pipeline
  step ValidateQuantity
  step FetchPrice
  step ComputeTotal
end

class PipelineResultSpec::HandledOrderPipeline < OperationCr::Pipeline
  step ValidateQuantity
  step FetchPrice
  step ComputeTotal

  on_step_failure do |failure, step_name|
    {ok: false, codes: failure.codes, failed_at: step_name}
  end
end

# Both handlers in one pipeline: `on_failure` for raised exceptions,
# `on_step_failure` for returned Failures. They must not shadow each other.
class PipelineResultSpec::BothHandlersPipeline < OperationCr::Pipeline
  step ValidateQuantity
  step :kaboom, Explodes

  on_failure do |ex, step_name|
    {kind: :exception, message: ex.message, failed_at: step_name}
  end

  on_step_failure do |failure, step_name|
    {kind: :result_failure, message: failure.first_error.code.to_s, failed_at: step_name}
  end
end

# `on_step_failure` must run OUTSIDE the region `on_failure` protects.
# Otherwise an exception raised by the step-failure handler is caught by
# `on_failure` and misreported as the *step* raising, under the step's name.
class PipelineResultSpec::HandlerRaisesPipeline < OperationCr::Pipeline
  step ValidateQuantity
  step :kaboom, Explodes

  on_failure do |ex, step_name|
    {kind: :exception, message: ex.message, failed_at: step_name}
  end

  on_step_failure do |failure, step_name|
    raise ArgumentError.new("boom from on_step_failure") if failure.codes.includes?(:not_positive)
    {kind: :result_failure, message: failure.first_error.code.to_s, failed_at: step_name}
  end
end

class PipelineResultSpec::PlainPipeline < OperationCr::Pipeline
  step PlainA
  step PlainB
end

private def reset_call_counters
  PipelineResultSpec::ValidateQuantity.calls = 0
  PipelineResultSpec::FetchPrice.calls = 0
  PipelineResultSpec::ComputeTotal.calls = 0
end

describe "OperationCr::Pipeline with Results" do
  describe "happy path" do
    it "merges the UNWRAPPED NamedTuple of a Success step into the context" do
      result = PipelineResultSpec::OrderPipeline.call(quantity: 3, product_id: 2)
      result.should_not be_a OperationCr::Failure
      context = result.as(NamedTuple(quantity: Int32, product_id: Int32, validated: Bool, unit_price: Int32, total: Int32))
      context[:validated].should be_true
      context[:unit_price].should eq 200
      context[:total].should eq 600
    end
  end

  describe "short-circuiting" do
    it "stops at the failing step and returns its Failure" do
      reset_call_counters
      result = PipelineResultSpec::OrderPipeline.call(quantity: 0, product_id: 2)

      failure = result.as(OperationCr::Failure)
      failure.codes.should eq [:not_positive]
      failure.first_error.field.should eq "quantity"
      failure.first_error.detail.should eq "got 0"
    end

    it "does not run any later step" do
      reset_call_counters
      PipelineResultSpec::OrderPipeline.call(quantity: 0, product_id: 2)

      PipelineResultSpec::ValidateQuantity.calls.should eq 1
      PipelineResultSpec::FetchPrice.calls.should eq 0
      PipelineResultSpec::ComputeTotal.calls.should eq 0
    end

    it "short-circuits mid-way too, running only the steps before the failure" do
      reset_call_counters
      result = PipelineResultSpec::OrderPipeline.call(quantity: 3, product_id: 0)

      result.as(OperationCr::Failure).codes.should eq [:unknown_product]
      PipelineResultSpec::ValidateQuantity.calls.should eq 1
      PipelineResultSpec::FetchPrice.calls.should eq 1
      PipelineResultSpec::ComputeTotal.calls.should eq 0
    end

    it "types the pipeline as `context | Failure`" do
      typeof(PipelineResultSpec::OrderPipeline.call(quantity: 1, product_id: 1)).should eq(
        Union(
          NamedTuple(quantity: Int32, product_id: Int32, validated: Bool, unit_price: Int32, total: Int32),
          OperationCr::Failure,
        )
      )
    end
  end

  describe "on_step_failure" do
    it "fires with the Failure and the failing step's name" do
      result = PipelineResultSpec::HandledOrderPipeline.call(quantity: 0, product_id: 2)
      result[:ok]?.should be_false
      result[:codes]?.should eq [:not_positive]
      result[:failed_at]?.should eq :validate_quantity
    end

    it "reports the name of whichever step failed" do
      result = PipelineResultSpec::HandledOrderPipeline.call(quantity: 3, product_id: 0)
      result[:failed_at]?.should eq :fetch_price
      result[:codes]?.should eq [:unknown_product]
    end

    it "its return value becomes the pipeline's return value" do
      result = PipelineResultSpec::HandledOrderPipeline.call(quantity: 0, product_id: 2)
      result.should_not be_a OperationCr::Failure
    end

    it "does not interfere with the happy path" do
      result = PipelineResultSpec::HandledOrderPipeline.call(quantity: 2, product_id: 3)
      result[:total]?.should eq 600
      result[:ok]?.should be_nil
    end
  end

  describe "on_step_failure alongside on_failure" do
    it "routes a returned Failure to on_step_failure" do
      result = PipelineResultSpec::BothHandlersPipeline.call(quantity: 0)
      result[:kind].should eq :result_failure
      result[:message].should eq "not_positive"
      result[:failed_at].should eq :validate_quantity
    end

    it "routes a raised exception to on_failure" do
      result = PipelineResultSpec::BothHandlersPipeline.call(quantity: 5)
      result[:kind].should eq :exception
      result[:message].should eq "boom from Explodes"
      result[:failed_at].should eq :kaboom
    end

    # The handler runs outside the begin/rescue that on_failure protects, so
    # its own exception is the caller's problem, not a fake "the step raised".
    it "propagates an exception raised inside on_step_failure" do
      expect_raises(ArgumentError, "boom from on_step_failure") do
        PipelineResultSpec::HandlerRaisesPipeline.call(quantity: 0)
      end
    end

    it "still routes a step's own exception to on_failure in the same pipeline" do
      result = PipelineResultSpec::HandlerRaisesPipeline.call(quantity: 5)
      result[:kind]?.should eq :exception
      result[:message]?.should eq "boom from Explodes"
      result[:failed_at]?.should eq :kaboom
    end
  end

  describe "pipelines of plain NamedTuple steps" do
    it "still returns the merged context" do
      PipelineResultSpec::PlainPipeline.call(a: 1).should eq({a: 1, b: 2, c: 20})
    end

    # The point of the whole design: the Failure guard is emitted for every
    # step, but Crystal prunes it where it is statically unreachable. A
    # plain pipeline's inferred return type must therefore be the bare
    # NamedTuple — no phantom `| OperationCr::Failure` — even though this
    # program has the Result module loaded.
    it "infers the bare NamedTuple, with no Failure in the union" do
      typeof(PipelineResultSpec::PlainPipeline.call(a: 1)).should eq NamedTuple(a: Int32, b: Int32, c: Int32)
    end

    it "leaves a pre-existing 0.2.0 pipeline's inferred type untouched" do
      typeof(PipelineSpec::HappyPipeline.call(name: "W", greeting: "Hi")).should eq(
        NamedTuple(name: String, greeting: String, shouted: Bool, message: String)
      )
    end
  end
end
