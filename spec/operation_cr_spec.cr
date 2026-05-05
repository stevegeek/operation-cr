require "./spec_helper"

class GreetUser < OperationCr::Operation
  param name : String
  param greeting : String = "Hello"

  def perform
    "#{greeting}, #{name}!"
  end
end

class TracedOp < OperationCr::Operation
  param x : Int32

  getter prepared = false
  getter before_called = false
  getter after_called = false

  def prepare
    @prepared = true
  end

  def before_execute
    @before_called = true
  end

  def after_execute(result)
    @after_called = true
    result.to_s + "!"
  end

  def perform
    x * 2
  end
end

describe OperationCr::Operation do
  describe ".call" do
    it "executes with all required keyword args" do
      GreetUser.call(name: "World").should eq "Hello, World!"
    end

    it "uses defaults when optional params omitted" do
      GreetUser.call(name: "Alice").should eq "Hello, Alice!"
    end

    it "accepts overrides for params with defaults" do
      GreetUser.call(name: "Alice", greeting: "Hi").should eq "Hi, Alice!"
    end
  end

  describe "lifecycle" do
    it "calls prepare on initialization, then before_execute and after_execute around perform" do
      op = TracedOp.new(x: 21)
      op.prepared.should be_true
      op.before_called.should be_false
      op.after_called.should be_false

      result = op.call
      op.before_called.should be_true
      op.after_called.should be_true
      result.should eq "42!"
    end
  end

  describe ".with (partial application)" do
    it "returns a PartiallyApplied that .call completes" do
      welcomer = GreetUser.with(greeting: "Welcome")
      welcomer.call(name: "Bob").should eq "Welcome, Bob!"
    end

    it "supports chained .with" do
      step1 = GreetUser.with(greeting: "Howdy")
      step2 = step1.with(name: "Carol")
      step2.call.should eq "Howdy, Carol!"
    end

    it "lets later .with calls override earlier values" do
      base = GreetUser.with(greeting: "Hi", name: "Dan")
      base.call.should eq "Hi, Dan!"
      base.call(greeting: "Yo").should eq "Yo, Dan!"
    end
  end
end
