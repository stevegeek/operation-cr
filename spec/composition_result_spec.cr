require "./spec_helper"
require "../src/operation_cr/result"

alias CompositionResultSpecInt = OperationCr::Success(Int32) | OperationCr::Failure

class CompositionResultSpec::ParseInt < OperationCr::Operation
  param raw : String

  def perform : CompositionResultSpecInt
    parsed = raw.to_i?
    return OperationCr::Failure.new(:not_a_number, "raw", raw) if parsed.nil?
    OperationCr::Success.new(parsed)
  end
end

class CompositionResultSpec::Halve < OperationCr::Operation
  class_property calls : Int32 = 0

  param n : Int32

  def perform : CompositionResultSpecInt
    @@calls += 1
    return OperationCr::Failure.new(:odd, "n") if n.odd?
    OperationCr::Success.new(n // 2)
  end
end

class CompositionResultSpec::Describe < OperationCr::Operation
  class_property calls : Int32 = 0

  param n : Int32

  def perform : String
    @@calls += 1
    "n=#{n}"
  end
end

class CompositionResultSpec::Double < OperationCr::Operation
  param x : Int32

  def perform : Int32
    x * 2
  end
end

describe "Chain#and_then" do
  describe "with a next operation" do
    it "passes the unwrapped Success payload to the block" do
      chain = CompositionResultSpec::ParseInt.and_then(CompositionResultSpec::Halve) { |n| {n: n} }
      chain.call(raw: "10").should eq OperationCr::Success.new(5)
    end

    it "short-circuits on Failure without running the block or the next op" do
      CompositionResultSpec::Halve.calls = 0
      chain = CompositionResultSpec::ParseInt.and_then(CompositionResultSpec::Halve) { |n| {n: n} }

      result = chain.call(raw: "not a number")

      result.should be_a OperationCr::Failure
      CompositionResultSpec::Halve.calls.should eq 0
    end

    it "carries the original errors through to the chain's result" do
      chain = CompositionResultSpec::ParseInt.and_then(CompositionResultSpec::Halve) { |n| {n: n} }
      failure = chain.call(raw: "xyz").as(OperationCr::Failure)
      failure.codes.should eq [:not_a_number]
      failure.first_error.field.should eq "raw"
      failure.first_error.detail.should eq "xyz"
    end

    it "propagates a Failure produced by a later step, blocks after it not run" do
      CompositionResultSpec::Describe.calls = 0
      chain = CompositionResultSpec::ParseInt
        .and_then(CompositionResultSpec::Halve) { |n| {n: n} }
        .and_then(CompositionResultSpec::Describe) { |n| {n: n} }

      # 7 is odd, so Halve fails and Describe must never run.
      chain.call(raw: "7").as(OperationCr::Failure).codes.should eq [:odd]
      CompositionResultSpec::Describe.calls.should eq 0

      chain.call(raw: "8").should eq "n=4"
      CompositionResultSpec::Describe.calls.should eq 1
    end
  end

  describe "block-only form" do
    it "transforms the unwrapped payload" do
      chain = CompositionResultSpec::ParseInt.and_then { |n| n + 100 }
      chain.call(raw: "5").should eq 105
    end

    it "does not run the block on Failure" do
      ran = false
      chain = CompositionResultSpec::ParseInt.and_then do |n|
        ran = true
        n + 100
      end
      chain.call(raw: "nope").should be_a OperationCr::Failure
      ran.should be_false
    end
  end

  describe "mixing plain and Result steps" do
    it "chains a plain op into a Result op and back out again" do
      chain = CompositionResultSpec::Double
        .then(CompositionResultSpec::ParseInt) { |x| {raw: x.to_s} }
        .and_then(CompositionResultSpec::Describe) { |n| {n: n} }

      chain.call(x: 21).should eq "n=42"
    end

    it "types the mixed chain as String | Failure" do
      chain = CompositionResultSpec::Double
        .then(CompositionResultSpec::ParseInt) { |x| {raw: x.to_s} }
        .and_then(CompositionResultSpec::Describe) { |n| {n: n} }

      typeof(chain.call(x: 21)).should eq Union(String, OperationCr::Failure)
    end
  end

  describe "chains that never touch a Result" do
    it "leaves `.then`'s inferred type completely unchanged" do
      chain = CompositionResultSpec::Double.then(CompositionResultSpec::Describe) { |x| {n: x} }
      typeof(chain.call(x: 4)).should eq String
      chain.call(x: 4).should eq "n=8"
    end

    it "degrades `and_then` to `then` with no Failure in the type" do
      chain = CompositionResultSpec::Double.and_then { |x| x + 1 }
      typeof(chain.call(x: 4)).should eq Int32
      chain.call(x: 4).should eq 9
    end
  end

  describe "`.then` semantics are untouched" do
    it "still hands `.then` the WRAPPED Result, block always runs" do
      ran = false
      chain = CompositionResultSpec::ParseInt.then do |result|
        ran = true
        result.is_a?(OperationCr::Failure) ? "failed" : "got #{result.value}"
      end

      chain.call(raw: "3").should eq "got 3"
      chain.call(raw: "x").should eq "failed"
      ran.should be_true
    end
  end
end
