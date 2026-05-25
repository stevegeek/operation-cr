module OperationCr
  module Instrumentation
    # Renders a Trace and its children as an ASCII tree. Plain text — no
    # ANSI colors.
    #
    # Format:
    #
    #     OpName(param: "value", other: 1) → "result" (1.23ms)
    #     ├── ChildOp(arg: 2) → 4 (0.10ms)
    #     │   └── GrandchildOp() → :ok (0.02ms)
    #     └── SiblingOp() ✗ ArgumentError: bad value (0.04ms)
    class TreeFormatter
      def initialize
      end

      def format(trace : Trace) : String
        String.build do |io|
          render(io, trace, prefix: "", is_last: true, is_root: true)
        end
      end

      private def render(io, trace, prefix, is_last, is_root)
        if is_root
          io << format_line(trace)
          io << '\n'
          line_prefix = ""
        else
          io << prefix
          io << (is_last ? "└── " : "├── ")
          io << format_line(trace)
          io << '\n'
          line_prefix = prefix + (is_last ? "    " : "│   ")
        end

        trace.children.each_with_index do |child, i|
          render(io, child, line_prefix, is_last: i == trace.children.size - 1, is_root: false)
        end
      end

      private def format_line(trace : Trace) : String
        String.build do |io|
          io << trace.operation_name
          io << '('
          io << format_params(trace.params)
          io << ')'

          if ex = trace.exception
            io << " ✗ "
            io << ex.class.name
            io << ": "
            io << ex.message
          else
            if r = trace.result
              io << " → "
              io << r
            end
          end

          if ms = trace.duration_ms
            io << " ("
            io << ms.round(2)
            io << "ms)"
          end
        end
      end

      # Empty params (e.g. the synthetic `<block>` root trace from
      # `Instrumentation.explaining`, or an operation with no declared
      # params) render as `OpName()` — `join(", ")` over an empty
      # collection yields an empty string, which is the desired output.
      private def format_params(params : Hash(Symbol, String)) : String
        params.map { |k, v| "#{k}: #{v}" }.join(", ")
      end
    end
  end
end
