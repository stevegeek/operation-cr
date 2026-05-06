require "./instrumentation/trace"
require "./instrumentation/tree_formatter"

module OperationCr
  # Tracing for operation execution.
  #
  #   GreetUser.explain(name: "Alice", greeting: "Welcome")
  #
  # Prints (default to STDOUT):
  #
  #   GreetUser(name: "Alice", greeting: "Welcome") → "Welcome, Alice!" (0.12ms)
  #
  # When the explained operation calls other operations during `perform`
  # (or via a `Chain`), each nested call adds itself as a child trace —
  # the formatter shows the full call tree.
  #
  # Trace state is class-level (not Fiber-local). Concurrent tracing
  # from multiple fibers would interleave; the intended use is single-
  # fiber debugging.
  module Instrumentation
    @@stack = [] of Trace
    class_property output : IO = STDOUT

    def self.current_trace : Trace?
      @@stack.last?
    end

    def self.tracing? : Bool
      !@@stack.empty?
    end

    def self.push(trace : Trace) : Nil
      if parent = current_trace
        parent.add_child(trace)
      end
      @@stack << trace
    end

    def self.pop : Trace?
      @@stack.pop?
    end

    def self.clear! : Nil
      @@stack.clear
    end

    # Run `block` with tracing on. Prints the resulting trace tree to
    # `Instrumentation.output` and returns the block's result. If the
    # block raises, the trace is still printed before the exception
    # propagates.
    def self.explaining(&)
      root = Trace.new(operation_class: nil, params: {} of Symbol => String)
      push(root)

      begin
        result = yield
        root.finish!(result: nil)
        root.children.each do |child|
          output.puts(TreeFormatter.new.format(child))
        end
        result
      rescue e
        root.finish!(exception: e)
        root.children.each do |child|
          output.puts(TreeFormatter.new.format(child))
        end
        raise e
      ensure
        pop
      end
    end
  end
end
