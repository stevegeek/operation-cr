require "./spec_helper"

class AddPositional < OperationCr::Operation
  positional_param a : Int32
  positional_param b : Int32

  def perform
    a + b
  end
end

class GreetPositional < OperationCr::Operation
  positional_param name : String
  positional_param greeting : String = "Hello"

  def perform
    "#{greeting}, #{name}!"
  end
end

class MixedOp < OperationCr::Operation
  positional_param subject : String
  param greeting : String = "Hi"
  param punctuation : String = "!"

  def perform
    "#{greeting}, #{subject}#{punctuation}"
  end
end

class TwoPosOneKw < OperationCr::Operation
  positional_param x : Int32
  positional_param y : Int32
  param scale : Int32 = 1

  def perform
    (x + y) * scale
  end
end

describe "positional params" do
  describe ".call" do
    it "accepts required positional args" do
      AddPositional.call(2, 3).should eq 5
    end

    it "uses default for optional positional when omitted" do
      GreetPositional.call("World").should eq "Hello, World!"
    end

    it "accepts overrides for optional positional" do
      GreetPositional.call("World", "Hi").should eq "Hi, World!"
    end

    it "exposes positional params via getters" do
      op = AddPositional.new(7, 8)
      op.a.should eq 7
      op.b.should eq 8
    end
  end

  describe "mixed positional + keyword" do
    it "supports positional before keyword params" do
      MixedOp.call("Alice").should eq "Hi, Alice!"
    end

    it "accepts keyword overrides alongside positionals" do
      MixedOp.call("Alice", greeting: "Hey", punctuation: ".").should eq "Hey, Alice."
    end

    it "two positionals plus a keyword" do
      TwoPosOneKw.call(2, 3).should eq 5
      TwoPosOneKw.call(2, 3, scale: 10).should eq 50
    end
  end

  describe ".with (partial application with positionals)" do
    it "binds positionals via .with and completes with .call" do
      adder = AddPositional.with(10)
      adder.call(5).should eq 15
    end

    it "supports binding all positionals through chained .with" do
      step1 = AddPositional.with(1)
      step2 = step1.with(2)
      step2.call.should eq 3
    end

    it "mixes positional and keyword binding" do
      tagged = MixedOp.with("Bob", greeting: "Yo")
      tagged.call.should eq "Yo, Bob!"
    end

    it "accepts later positional + keyword overrides at .call time" do
      welcomer = MixedOp.with(greeting: "Welcome")
      welcomer.call("Carol", punctuation: "?").should eq "Welcome, Carol?"
    end
  end
end
