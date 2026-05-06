require "./spec_helper"

class Double < OperationCr::Operation
  param x : Int32

  def perform : Int32
    x * 2
  end
end

class Stringify < OperationCr::Operation
  param value : Int32

  def perform : String
    "result=#{value}"
  end
end

class Shout < OperationCr::Operation
  param message : String

  def perform : String
    message.upcase + "!"
  end
end

class SumOp < OperationCr::Operation
  positional_param a : Int32
  positional_param b : Int32 = 0
  param multiplier : Int32 = 1

  def perform : Int32
    (a + b) * multiplier
  end
end

describe "OperationCr::Operation .then composition" do
  describe "two-op chain" do
    it "passes the head's result through the block to the next op" do
      chain = Double.then(Stringify) { |r| {value: r} }
      chain.call(x: 21).should eq "result=42"
    end

    it "is itself callable like an operation (forwards kwargs to the head)" do
      chain = Double.then(Stringify) { |r| {value: r} }
      # chain.call accepts the head's kwargs
      chain.call(x: 5).should eq "result=10"
    end
  end

  describe "three-op chain" do
    it "composes three operations sequentially" do
      chain = Double
        .then(Stringify) { |r| {value: r} }
        .then(Shout) { |s| {message: s} }
      chain.call(x: 21).should eq "RESULT=42!"
    end
  end

  describe "block-only transform (.then with no second op)" do
    it "transforms the head's result without invoking another op" do
      inc = Double.then { |r| r + 1 }
      inc.call(x: 10).should eq 21
    end

    it "can be mixed with op-based steps" do
      chain = Double
        .then(Stringify) { |r| {value: r} }
        .then { |s| s + " woo" }
      chain.call(x: 5).should eq "result=10 woo"
    end

    it "supports a sequence of pure transforms" do
      chain = Double
        .then { |r| r + 1 }
        .then(&.to_s)
      chain.call(x: 4).should eq "9"
    end
  end

  describe ".with partial application on a chain" do
    it "lets you bind some of the head's kwargs and call later" do
      chain = Double.then(Stringify) { |r| {value: r} }
      preset = chain.with(x: 7)
      preset.call.should eq "result=14"
    end

    it "supports chained .with overrides" do
      chain = Double.then(Stringify) { |r| {value: r} }
      preset = chain.with(x: 7).with(x: 3)
      preset.call.should eq "result=6"
    end
  end

  describe "chains with a positional-arg head op" do
    it "forwards positional args through Chain.call" do
      chain = SumOp.then(Stringify) { |n| {value: n} }
      chain.call(2, 3).should eq "result=5"
    end

    it "forwards mixed positional + keyword through Chain.call" do
      chain = SumOp.then(Stringify) { |n| {value: n} }
      chain.call(2, 3, multiplier: 10).should eq "result=50"
    end

    it "supports partial application of positional + keyword via Chain#with" do
      chain = SumOp.then(Stringify) { |n| {value: n} }
      preset = chain.with(7, multiplier: 2)
      preset.call.should eq "result=14"
      preset.call(3).should eq "result=20"
    end
  end
end
