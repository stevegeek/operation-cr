module OperationCr
  module Instrumentation
    # A single operation execution recorded for trace output.
    # Nests other traces via `children` when one operation calls another
    # while tracing is active.
    class Trace
      # Typed as `Operation.class?` (i.e. `Operation.class | Nil`); `nil`
      # for the synthetic root trace inside `Instrumentation.explaining`.
      # NOTE: Crystal stores metaclass values here as `Class`, so
      # subclass-specific class methods (e.g. `cls.required_keyword_params`)
      # are not reachable through this getter without an
      # `as(SomeSubclass.class)` cast. The current `TreeFormatter` only
      # calls `cls.name`, which is fine; if a future formatter wants
      # to introspect per-subclass metadata, it'll need that cast.
      getter operation_class : OperationCr::Operation.class | Nil
      getter params : Hash(Symbol, String)
      getter start_time : Time::Instant
      property end_time : Time::Instant?
      property result : String?
      property exception : Exception?
      getter children = [] of Trace

      def initialize(@operation_class, @params)
        @start_time = Time.instant
      end

      def finish!(result : String? = nil, exception : Exception? = nil) : self
        @end_time = Time.instant
        @result = result
        @exception = exception
        self
      end

      def duration_ms : Float64?
        if et = @end_time
          (et - @start_time).total_milliseconds
        end
      end

      def add_child(trace : Trace) : Nil
        @children << trace
      end

      def operation_name : String
        cls = @operation_class
        cls ? cls.name : "<block>"
      end

      def success? : Bool
        @exception.nil?
      end
    end
  end
end
