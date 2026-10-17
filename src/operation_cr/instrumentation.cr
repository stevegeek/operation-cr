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
  # Trace state is fiber-local: each fiber gets its own stack keyed by
  # `Fiber.current.object_id`. Concurrent `.explain` calls from
  # different fibers produce independent trace trees and do not
  # cross-contaminate (`clear!` only clears the calling fiber's stack).
  module Instrumentation
    # Hash(fiber_id => Array(Trace)). Hash lookups themselves are not
    # atomic, so this still assumes the runtime's MT scheduler does not
    # preempt mid-`[]=` — which matches Crystal 1.x's cooperative model.
    @@stacks = {} of UInt64 => Array(Trace)

    # Module-level destination for trace output. Unlike `@@stacks`, this
    # is a single class variable shared by all fibers — it is **not**
    # fiber-keyed.
    #
    # Concurrent `.explain(io: io)` / `.explaining(io: io)` calls are
    # safe because `explaining` snapshots `output` into a local
    # `target` IO before yielding, so each fiber writes to its own IO
    # regardless of subsequent setter calls. However, code that reads
    # `OperationCr::Instrumentation.output` directly from multiple
    # fibers races against any concurrent setter — the read may observe
    # a value written by another fiber.
    #
    # Recommended: pass `io:` to `.explain` / `.explaining` rather than
    # mutating the singleton. Reserve direct `output =` for process-wide
    # setup (test harnesses, single-threaded scripts) where no other
    # fiber is concurrently reading or writing.
    class_property output : IO = STDOUT

    private def self.current_stack : Array(Trace)
      @@stacks[::Fiber.current.object_id] ||= [] of Trace
    end

    def self.current_trace : Trace?
      stack = @@stacks[::Fiber.current.object_id]?
      stack ? stack.last? : nil
    end

    def self.tracing? : Bool
      stack = @@stacks[::Fiber.current.object_id]?
      !stack.nil? && !stack.empty?
    end

    def self.push(trace : Trace) : Nil
      stack = current_stack
      if parent = stack.last?
        parent.add_child(trace)
      end
      stack << trace
    end

    def self.pop : Trace?
      fid = ::Fiber.current.object_id
      stack = @@stacks[fid]?
      return unless stack
      result = stack.pop?
      @@stacks.delete(fid) if stack.empty?
      result
    end

    # Clears only the calling fiber's trace stack. Other fibers'
    # in-flight traces are untouched.
    def self.clear! : Nil
      @@stacks.delete(::Fiber.current.object_id)
    end

    # Run `block` with tracing on. Prints the resulting trace tree to
    # `io` (defaults to the module-level `Instrumentation.output`) and
    # returns the block's result. If the block raises, the trace is
    # still printed before the exception propagates.
    def self.explaining(io : IO? = nil, &)
      target = io || output
      root = Trace.new(operation_class: nil, params: {} of Symbol => String)
      push(root)

      begin
        result = yield
        root.finish!(result: nil)
        root.children.each do |child|
          target.puts(TreeFormatter.new.format(child))
        end
        result
      rescue e
        root.finish!(exception: e)
        root.children.each do |child|
          target.puts(TreeFormatter.new.format(child))
        end
        raise e
      ensure
        pop
      end
    end
  end
end
