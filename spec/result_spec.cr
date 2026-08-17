require "./spec_helper"
require "../src/operation_cr/result"

# The Result type is opt-in, so this file requires it explicitly rather
# than pulling it into `spec_helper`. Note that once *any* spec file
# requires it, the whole suite compiles with it loaded — which is exactly
# the interesting condition for `pipeline_result_spec.cr`, where a plain
# pipeline must still infer its pre-0.3.0 return type.

# There is no `Result(T)` type name (Crystal has no generic aliases), so
# call sites write the union or a local non-generic alias like this one.
alias ResultSpecInt = OperationCr::Success(Int32) | OperationCr::Failure
alias ResultSpecStr = OperationCr::Success(String) | OperationCr::Failure

# Exhaustive `case/in` over the union. Deleting the `Failure` branch here
# is a compile error — see `examples/should_fail_non_exhaustive_result.cr`.
private def describe_result(result : ResultSpecInt) : String
  case result
  in OperationCr::Success
    # No unwrap, no nil check, no rescue: `value` is statically Int32.
    "ok:#{result.value + 1}"
  in OperationCr::Failure
    "err:#{result.codes.join(",")}"
  end
end

describe OperationCr::Error do
  it "carries a code, an optional field and optional detail" do
    error = OperationCr::Error.new(:too_short, "name", "min 3 chars")
    error.code.should eq :too_short
    error.field.should eq "name"
    error.detail.should eq "min 3 chars"
  end

  it "defaults field and detail to nil" do
    error = OperationCr::Error.new(:boom)
    error.field.should be_nil
    error.detail.should be_nil
  end
end

describe OperationCr::Success do
  it "exposes its payload with the payload's own type" do
    OperationCr::Success.new(41).value.should eq 41
    OperationCr::Success.new("hi").value.should eq "hi"
  end

  it "is ok?" do
    OperationCr::Success.new(1).ok?.should be_true
  end

  describe "#and_then" do
    it "runs the block with the unwrapped value" do
      seen = 0
      result = OperationCr::Success.new(41).and_then do |value|
        seen = value
        OperationCr::Success.new(value + 1).as(ResultSpecInt)
      end
      seen.should eq 41
      result.should eq OperationCr::Success.new(42)
    end

    it "chains, and a failure mid-chain survives to the end" do
      result = OperationCr::Success.new(4)
        .and_then { |n| OperationCr::Success.new(n * 2).as(ResultSpecInt) }
        .and_then { |n| OperationCr::Failure.new(:too_big, "n", "#{n} > 5").as(ResultSpecInt) }
        .and_then { |n| OperationCr::Success.new(n + 1000).as(ResultSpecInt) }

      result.should be_a OperationCr::Failure
      result.as(OperationCr::Failure).codes.should eq [:too_big]
      result.as(OperationCr::Failure).first_error.detail.should eq "8 > 5"
    end
  end

  describe "#map" do
    it "transforms the payload and re-wraps it" do
      OperationCr::Success.new(21).map { |n| n * 2 }.should eq OperationCr::Success.new(42)
    end

    it "can change the payload type" do
      OperationCr::Success.new(42).map(&.to_s).should eq OperationCr::Success.new("42")
    end

    it "keeps a union-typed receiver a union, so exhaustiveness survives" do
      # On a concrete Success the compiler narrows to Success(String),
      # which is more precise and still exhaustive. What matters is that
      # mapping a value whose static type is the union keeps both arms.
      start = OperationCr::Success.new(1).as(ResultSpecInt)
      typeof(start.map(&.to_s)).should eq ResultSpecStr
    end
  end
end

describe OperationCr::Failure do
  it "builds from a single code, with optional field and detail" do
    failure = OperationCr::Failure.new(:invalid, "email", "no @")
    failure.errors.size.should eq 1
    failure.first_error.code.should eq :invalid
    failure.first_error.field.should eq "email"
    failure.first_error.detail.should eq "no @"
  end

  it "builds from an array of errors" do
    failure = OperationCr::Failure.new([
      OperationCr::Error.new(:a),
      OperationCr::Error.new(:b),
    ])
    failure.errors.size.should eq 2
  end

  it "is not ok?" do
    OperationCr::Failure.new(:nope).ok?.should be_false
  end

  it "exposes the first error" do
    failure = OperationCr::Failure.new([OperationCr::Error.new(:a), OperationCr::Error.new(:b)])
    failure.first_error.code.should eq :a
  end

  it "exposes every code in order" do
    failure = OperationCr::Failure.new([OperationCr::Error.new(:a), OperationCr::Error.new(:b)])
    failure.codes.should eq [:a, :b]
  end

  # `Failure` is a value type: copying it must copy the failure, not a
  # pointer to one shared error array. Both routes into that array are
  # closed — the constructor argument and the `errors` getter.
  it "does not share the caller's array" do
    errors = [OperationCr::Error.new(:a)]
    failure = OperationCr::Failure.new(errors)
    errors << OperationCr::Error.new(:injected_via_caller_array)
    failure.codes.should eq [:a]
  end

  it "does not hand out the array it holds" do
    failure = OperationCr::Failure.new([OperationCr::Error.new(:a)])
    failure.errors << OperationCr::Error.new(:injected_via_getter)
    failure.codes.should eq [:a]
  end

  it "keeps a copy of itself independent of both routes" do
    errors = [OperationCr::Error.new(:a)]
    fail_a = OperationCr::Failure.new(errors)
    fail_b = fail_a
    errors << OperationCr::Error.new(:injected_via_caller_array)
    fail_b.errors << OperationCr::Error.new(:injected_via_getter)
    fail_a.codes.should eq [:a]
    fail_b.codes.should eq [:a]
  end

  it "combines with another failure, concatenating errors" do
    combined = OperationCr::Failure.new(:a, "one") + OperationCr::Failure.new(:b, "two")
    combined.codes.should eq [:a, :b]
    combined.errors.map(&.field).should eq ["one", "two"]
  end

  describe "#and_then" do
    it "returns self and does NOT run the block" do
      ran = false
      failure = OperationCr::Failure.new(:stop)
      result = failure.and_then do |value|
        ran = true
        OperationCr::Success.new(value).as(ResultSpecInt)
      end
      ran.should be_false
      result.should eq failure
    end
  end

  describe "#map" do
    it "returns self and does NOT run the block" do
      ran = false
      failure = OperationCr::Failure.new(:stop)
      result = failure.map do |value|
        ran = true
        value
      end
      ran.should be_false
      result.should eq failure
    end
  end
end

describe "Success(T) | Failure exhaustiveness" do
  it "matches both branches of an exhaustive case/in" do
    describe_result(OperationCr::Success.new(41)).should eq "ok:42"
    describe_result(OperationCr::Failure.new(:bad, "x")).should eq "err:bad"
  end

  it "short-circuits a union-typed and_then without running the block" do
    ran = false
    start = OperationCr::Failure.new(:nope).as(ResultSpecInt)
    result = start.and_then do |value|
      ran = true
      OperationCr::Success.new(value).as(ResultSpecInt)
    end
    ran.should be_false
    result.should be_a OperationCr::Failure
  end
end
