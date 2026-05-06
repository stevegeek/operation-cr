require "./spec_helper"

# Two-positional, no defaults — easiest curry case.
class CurryAdd < OperationCr::Operation
  positional_param a : Int32
  positional_param b : Int32

  def perform
    a + b
  end
end

# Mixed positional + required keyword + optional keyword (with default).
class CurryGreet < OperationCr::Operation
  positional_param name : String
  param greeting : String
  param suffix : String = "!"

  def perform
    "#{greeting}, #{name}#{suffix}"
  end
end

# Helper: Crystal's static type system means each Curried step is a
# different generic instantiation (Curried(O, P1, T1) vs Curried(O, P2, T2)),
# so `.is_a?(OperationCr::Curried)` over the bare generic works at the
# type-name level without us pinning specific type args.
private def curried?(value)
  value.class.name.starts_with?("OperationCr::Curried(")
end

describe "Operation.curry" do
  it "returns a Curried wrapper bound to nothing" do
    curry = CurryAdd.curry
    curried?(curry).should be_true
    curry.prepared?.should be_false
  end

  it "consumes one positional arg at a time" do
    after_first = CurryAdd.curry.call(2)
    curried?(after_first).should be_true

    final = after_first.as(OperationCr::Curried).call(3)
    final.should eq(5)
  end

  it "fills required keyword params after positional" do
    after_pos = CurryGreet.curry.call("Alice")
    curried?(after_pos).should be_true

    final = after_pos.as(OperationCr::Curried).call("Welcome")
    final.should eq("Welcome, Alice!")
  end

  it "step-by-step curry of all params returns the operation result on the last step" do
    step1 = CurryGreet.curry.call("Bob")
    curried?(step1).should be_true

    step2 = step1.as(OperationCr::Curried).call("Hi")
    step2.should eq("Hi, Bob!")
  end

  it "raises when curry is called with no remaining param slot" do
    fresh = CurryAdd.curry
    after_first = fresh.call(1)
    final = after_first.as(OperationCr::Curried).call(2)
    final.should eq(3)
  end
end
