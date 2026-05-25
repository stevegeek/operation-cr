require "./spec_helper"

class TraceGreet < OperationCr::Operation
  positional_param name : String
  param greeting : String = "Hello"

  def perform
    "#{greeting}, #{name}"
  end
end

class TraceAdd < OperationCr::Operation
  positional_param a : Int32
  positional_param b : Int32

  def perform
    a + b
  end
end

# Nests another op inside its perform — the trace tree should mirror
# the call structure.
class TraceNester < OperationCr::Operation
  positional_param name : String

  def perform
    inner = TraceGreet.call(name)
    "[wrapped] #{inner}"
  end
end

# Raises — trace should capture exception, not result.
class TraceBoom < OperationCr::Operation
  param msg : String = "boom"

  def perform
    raise ArgumentError.new(msg)
  end
end

private def captured_explain(*args, op_class, **kwargs)
  io = IO::Memory.new
  prev = OperationCr::Instrumentation.output
  OperationCr::Instrumentation.output = io
  OperationCr::Instrumentation.clear!
  result = op_class.explain(*args, **kwargs)
  {result, io.to_s}
ensure
  OperationCr::Instrumentation.output = prev || STDOUT
  OperationCr::Instrumentation.clear!
end

describe OperationCr::Instrumentation do
  describe "#tracing?" do
    it "is false outside an explaining block" do
      OperationCr::Instrumentation.clear!
      OperationCr::Instrumentation.tracing?.should be_false
    end

    it "is true inside an explaining block" do
      OperationCr::Instrumentation.clear!
      seen = false
      io = IO::Memory.new
      OperationCr::Instrumentation.output = io
      OperationCr::Instrumentation.explaining do
        seen = OperationCr::Instrumentation.tracing?
      end
      seen.should be_true
    ensure
      OperationCr::Instrumentation.output = STDOUT
      OperationCr::Instrumentation.clear!
    end
  end

  describe "Operation.explain" do
    it "returns the operation's result and prints a trace line" do
      result, output = captured_explain("Alice", greeting: "Welcome", op_class: TraceGreet)
      result.should eq("Welcome, Alice")
      output.should contain("TraceGreet")
      output.should contain(%(name: "Alice"))
      output.should contain(%(greeting: "Welcome"))
      output.should contain("→")
      output.should contain("Welcome, Alice")
      output.should match(/\d+(\.\d+)?ms/)
    end

    it "captures positional args in the trace params" do
      _, output = captured_explain(2, 3, op_class: TraceAdd)
      output.should contain("a: 2")
      output.should contain("b: 3")
      output.should contain("→ 5")
    end

    it "nests child traces when one operation calls another in perform" do
      result, output = captured_explain("Bob", op_class: TraceNester)
      result.should eq("[wrapped] Hello, Bob")
      # The output should show a tree: TraceNester at the top, with
      # TraceGreet as a child line.
      output.should contain("TraceNester")
      output.should contain("TraceGreet")
      # First line is the parent (no tree connector); a later line has
      # the └── or ├── connector for the child.
      (output.includes?("└──") || output.includes?("├──")).should be_true
    end

    it "records exceptions instead of results when perform raises" do
      io = IO::Memory.new
      prev = OperationCr::Instrumentation.output
      OperationCr::Instrumentation.output = io
      OperationCr::Instrumentation.clear!

      expect_raises(ArgumentError, "boom") do
        TraceBoom.explain
      end

      output = io.to_s
      output.should contain("TraceBoom")
      output.should contain("✗")
      output.should contain("ArgumentError")
      output.should contain("boom")
    ensure
      OperationCr::Instrumentation.output = prev || STDOUT
      OperationCr::Instrumentation.clear!
    end

    it "accepts an io: kwarg that overrides Instrumentation.output" do
      OperationCr::Instrumentation.clear!
      # Module-level output points at one IO; .explain(io: ...) writes
      # elsewhere. The module-level IO must stay untouched.
      module_io = IO::Memory.new
      explain_io = IO::Memory.new
      OperationCr::Instrumentation.output = module_io

      TraceGreet.explain("Zoe", io: explain_io)

      module_io.to_s.should be_empty
      explain_io.to_s.should contain("TraceGreet")
    ensure
      OperationCr::Instrumentation.output = STDOUT
      OperationCr::Instrumentation.clear!
    end

    it "does not affect output when called without explain" do
      OperationCr::Instrumentation.clear!
      io = IO::Memory.new
      OperationCr::Instrumentation.output = io
      TraceGreet.call("Eve") # plain call, no explain
      io.to_s.should be_empty
    ensure
      OperationCr::Instrumentation.output = STDOUT
    end
  end

  describe "fiber isolation" do
    # End-to-end smoke test: two `.explaining` blocks in separate fibers
    # should produce independent trace trees. Because each `spawn` body
    # runs to completion before yielding (no IO/sleep between push and
    # pop), this would also pass with a single class-level `@@stack` —
    # see the channel-rendezvous spec below for the real regression
    # guard.
    it "keeps each fiber's trace tree independent (smoke)" do
      OperationCr::Instrumentation.clear!

      io_a = IO::Memory.new
      io_b = IO::Memory.new

      done_a = Channel(Nil).new
      done_b = Channel(Nil).new

      spawn do
        OperationCr::Instrumentation.output = io_a
        OperationCr::Instrumentation.explaining { TraceNester.call("Alice") }
        done_a.send(nil)
      end

      spawn do
        OperationCr::Instrumentation.output = io_b
        OperationCr::Instrumentation.explaining { TraceAdd.call(7, 8) }
        done_b.send(nil)
      end

      done_a.receive
      done_b.receive

      io_a.to_s.should contain("TraceNester")
      io_a.to_s.should contain("TraceGreet")
      io_a.to_s.should_not contain("TraceAdd")

      io_b.to_s.should contain("TraceAdd")
      io_b.to_s.should_not contain("TraceNester")
    ensure
      OperationCr::Instrumentation.output = STDOUT
      OperationCr::Instrumentation.clear!
    end
  end
end
