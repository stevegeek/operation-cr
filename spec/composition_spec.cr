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
        .then { |r| r.to_s }
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
end
