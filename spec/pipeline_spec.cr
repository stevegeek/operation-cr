require "./spec_helper"

# Test operations for pipeline composition

class PipelineSpec::CaptureGreeting < OperationCr::Operation
  param name : String
  param greeting : String

  def perform : NamedTuple(message: String)
    {message: "#{greeting}, #{name}!"}
  end
end

class PipelineSpec::Loudify < OperationCr::Operation
  param message : String

  def perform : NamedTuple(message: String, shouted: Bool)
    {message: message.upcase, shouted: true}
  end
end

class PipelineSpec::AppendBang < OperationCr::Operation
  param message : String

  def perform : NamedTuple(message: String)
    {message: "#{message}!!!"}
  end
end

class PipelineSpec::AlwaysRaises < OperationCr::Operation
  param message : String

  def perform : NamedTuple(message: String)
    raise "boom from AlwaysRaises"
  end
end

# Side-effecting step that doesn't contribute new context. Pipelines
# require NamedTuple returns, so use NamedTuple.new for the "void" case.
class PipelineSpec::SideEffect < OperationCr::Operation
  class_property log : Array(String) = [] of String

  param message : String

  def perform : NamedTuple()
    @@log << "saw: #{message}"
    NamedTuple.new
  end
end

# Pipelines

class PipelineSpec::HappyPipeline < OperationCr::Pipeline
  step CaptureGreeting
  step Loudify
  step AppendBang
end

class PipelineSpec::FailingPipeline < OperationCr::Pipeline
  step CaptureGreeting
  step AlwaysRaises
  step AppendBang
end

class PipelineSpec::FailingPipelineWithHandler < OperationCr::Pipeline
  step CaptureGreeting
  step AlwaysRaises
  step AppendBang

  on_failure do |ex, step_name|
    {error: ex.message, failed_at: step_name}
  end
end

class PipelineSpec::VoidStepPipeline < OperationCr::Pipeline
  step CaptureGreeting
  step :log_it, SideEffect
  step AppendBang
end

class PipelineSpec::NamedStepPipeline < OperationCr::Pipeline
  step :greet, CaptureGreeting
  step :shout, Loudify
end

class PipelineSpec::PipelineWithBeforeStep < OperationCr::Pipeline
  class_property visited_steps : Array(Symbol) = [] of Symbol

  step CaptureGreeting
  step Loudify
  step AppendBang

  before_step do |_ctx, step_name|
    visited_steps << step_name
  end
end

class PipelineSpec::EmptyPipeline < OperationCr::Pipeline
end

class PipelineSpec::DuplicateStepPipeline < OperationCr::Pipeline
  step CaptureGreeting
  step AppendBang
  step :again, AppendBang
end

class PipelineSpec::NoParamsOp < OperationCr::Operation
  def perform : NamedTuple(stamp: String)
    {stamp: "ran"}
  end
end

class PipelineSpec::PipelineWithNoParamsStep < OperationCr::Pipeline
  step NoParamsOp
end

class PipelineSpec::FailingBeforeStepPipeline < OperationCr::Pipeline
  step CaptureGreeting
  step Loudify

  before_step do |_ctx, step_name|
    raise "exploded in before_step (step=#{step_name})" if step_name == :loudify
  end

  on_failure do |ex, step_name|
    {error: ex.message, failed_at: step_name}
  end
end

describe OperationCr::Pipeline do
  describe "basic happy path" do
    it "threads context through each step, merging results" do
      result = PipelineSpec::HappyPipeline.call(name: "World", greeting: "Hello")
      result[:message].should eq "HELLO, WORLD!!!!"
      result[:shouted].should be_true
      result[:name].should eq "World"
      result[:greeting].should eq "Hello"
    end

    it "preserves initial context keys not consumed by any step" do
      result = PipelineSpec::HappyPipeline.call(name: "Alice", greeting: "Hi", extra: "untouched")
      result[:extra].should eq "untouched"
    end
  end

  describe "void-returning steps" do
    it "calls the operation but does not modify context" do
      PipelineSpec::SideEffect.log.clear
      result = PipelineSpec::VoidStepPipeline.call(name: "Bob", greeting: "Hey")
      result[:message].should eq "Hey, Bob!!!!"
      PipelineSpec::SideEffect.log.should eq ["saw: Hey, Bob!"]
    end
  end

  describe "failure handling" do
    it "propagates exceptions when no on_failure is defined" do
      expect_raises(Exception, /boom from AlwaysRaises/) do
        PipelineSpec::FailingPipeline.call(name: "X", greeting: "Y")
      end
    end

    it "invokes on_failure handler when a step raises" do
      result = PipelineSpec::FailingPipelineWithHandler.call(name: "X", greeting: "Y")
      result[:error].should eq "boom from AlwaysRaises"
      result[:failed_at].should eq :always_raises
    end
  end

  describe "introspection" do
    it "exposes step_names in declaration order" do
      PipelineSpec::HappyPipeline.step_names.should eq [:capture_greeting, :loudify, :append_bang]
    end

    it "honours explicit step names" do
      PipelineSpec::NamedStepPipeline.step_names.should eq [:greet, :shout]
    end
  end

  describe "before_step hook" do
    it "fires before each step with that step's name" do
      PipelineSpec::PipelineWithBeforeStep.visited_steps.clear
      PipelineSpec::PipelineWithBeforeStep.call(name: "Eve", greeting: "Yo")
      PipelineSpec::PipelineWithBeforeStep.visited_steps.should eq [:capture_greeting, :loudify, :append_bang]
    end

    it "raised exception in before_step is routed through on_failure" do
      # The return type is a union of the success-path and handler-path
      # NamedTuples; use nilable lookup for keys that only exist on one
      # branch.
      result = PipelineSpec::FailingBeforeStepPipeline.call(name: "X", greeting: "Y")
      result[:error]?.try(&.starts_with?("exploded in before_step")).should be_true
      result[:failed_at]?.should eq :loudify
    end
  end

  describe "empty pipeline" do
    it "returns the initial context unchanged" do
      result = PipelineSpec::EmptyPipeline.call(a: 1, b: "two")
      result[:a].should eq 1
      result[:b].should eq "two"
    end
  end

  describe "duplicate step names" do
    it "step_names returns duplicates as-is (use explicit `step :name, Op` to disambiguate)" do
      PipelineSpec::DuplicateStepPipeline.step_names.should eq [:capture_greeting, :append_bang, :again]
    end
  end

  describe "operations with no params" do
    it "still runs and contributes its return-tuple to context" do
      result = PipelineSpec::PipelineWithNoParamsStep.call
      result[:stamp].should eq "ran"
    end
  end
end
