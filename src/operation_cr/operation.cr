module OperationCr
  abstract class Operation
    macro inherited
      # Ordered map of positional params: name => {type:, has_default:, default:}
      POSITIONAL_PARAMS = {} of Nil => Nil
      # Ordered map of keyword params: name => {type:, has_default:, default:}
      KW_PARAMS = {} of Nil => Nil

      macro finished
        __build_initialize
        __build_with
        __build_required_params
        __build_trace_params
      end
    end

    # Generates a per-instance helper that returns the current bound
    # params as a Hash(Symbol, String) for trace output. Stringification
    # uses .inspect so the format is unambiguous (quoted strings,
    # readable nils, etc.).
    macro __build_trace_params
      def __trace_params : Hash(Symbol, String)
        result = Hash(Symbol, String).new
        {% for name in @type.constant("POSITIONAL_PARAMS").keys %}
          result[{{ name }}] = {{ name.id }}.inspect
        {% end %}
        {% for name in @type.constant("KW_PARAMS").keys %}
          result[{{ name }}] = {{ name.id }}.inspect
        {% end %}
        result
      end
    end

    # Class-level introspection of which params are *required* (no default).
    # Used by Curried to know what's left to fill. Built per-subclass at
    # `finished` time so each operation's lists reflect only its own
    # declarations.
    macro __build_required_params
      {% pos_params = @type.constant("POSITIONAL_PARAMS") %}
      {% kw_params = @type.constant("KW_PARAMS") %}

      def self.required_positional_params : Array(Symbol)
        [
          {% for name, info in pos_params %}
            {% if !info[:has_default] %}{{ name }},{% end %}
          {% end %}
        ] of Symbol
      end

      def self.required_keyword_params : Array(Symbol)
        [
          {% for name, info in kw_params %}
            {% if !info[:has_default] %}{{ name }},{% end %}
          {% end %}
        ] of Symbol
      end

      def self.positional_param_names : Array(Symbol)
        [
          {% for name, info in pos_params %}
            {{ name }},
          {% end %}
        ] of Symbol
      end

      def self.keyword_param_names : Array(Symbol)
        [
          {% for name, info in kw_params %}
            {{ name }},
          {% end %}
        ] of Symbol
      end
    end

    macro __build_initialize
      {% pos_params = @type.constant("POSITIONAL_PARAMS") %}
      {% kw_params = @type.constant("KW_PARAMS") %}
      def initialize(
        {% for name, info in pos_params %}
          @{{ name.id }} : {{ info[:type] }}{% if info[:has_default] %} = {{ info[:default] }}{% end %},
        {% end %}
        {% if kw_params.size > 0 %}
        *,
        {% for name, info in kw_params %}
          @{{ name.id }} : {{ info[:type] }}{% if info[:has_default] %} = {{ info[:default] }}{% end %},
        {% end %}
        {% end %}
      )
        prepare
      end
    end

    # Generates a per-subclass `.with` that validates kwarg keys at compile
    # time against the subclass's `KW_PARAMS`. Unknown keys raise a clear
    # error at the user's call site rather than triggering a confusing
    # "missing argument" error deep inside `partially_applied.cr`.
    # Positional args can't be misspelled so they flow through unchecked.
    macro __build_with
      def self.with(*pos, **args : **T) forall T
        \{% for key in T.keys %}
          \{% if !@type.constant("KW_PARAMS").keys.map(&.id.stringify).includes?(key.id.stringify) %}
            \{% raise "unknown param `#{key.id}` for #{@type}. Valid params: #{@type.constant("KW_PARAMS").keys.map(&.id).join(", ").id}" %}
          \{% end %}
        \{% end %}
        ::OperationCr::PartiallyApplied(self, typeof(pos), T).new(pos, args)
      end
    end

    macro positional_param(decl)
      {% if !decl.is_a?(TypeDeclaration) %}
        {% raise "positional_param expects a type declaration like: positional_param name : String [= \"default\"]" %}
      {% end %}
      {%
        has_default = !decl.value.is_a?(Nop)
      %}
      {% if !has_default %}
        # Required positional cannot follow an optional positional
        {% for prev_name, prev_info in POSITIONAL_PARAMS %}
          {% if prev_info[:has_default] %}
            {% raise "required positional_param '#{decl.var.id}' cannot follow optional positional_param '#{prev_name.id}'" %}
          {% end %}
        {% end %}
      {% end %}
      {%
        POSITIONAL_PARAMS[decl.var.symbolize] = {
          type:        decl.type,
          has_default: has_default,
          default:     decl.value,
        }
      %}
      getter {{ decl.var.id }} : {{ decl.type }}
    end

    macro param(decl)
      {% if !decl.is_a?(TypeDeclaration) %}
        {% raise "param expects a type declaration like: param name : String [= \"default\"]" %}
      {% end %}
      {%
        has_default = !decl.value.is_a?(Nop)
        KW_PARAMS[decl.var.symbolize] = {
          type:        decl.type,
          has_default: has_default,
          default:     decl.value,
        }
      %}
      getter {{ decl.var.id }} : {{ decl.type }}
    end

    abstract def perform

    def call
      if ::OperationCr::Instrumentation.tracing?
        __traced_call
      else
        __plain_call
      end
    end

    private def __plain_call
      before_execute
      result = perform
      after_execute(result)
    end

    private def __traced_call
      trace = ::OperationCr::Instrumentation::Trace.new(
        operation_class: self.class,
        params: __trace_params,
      )
      ::OperationCr::Instrumentation.push(trace)

      begin
        result = __plain_call
        trace.finish!(result: result.inspect)
        result
      rescue e
        trace.finish!(exception: e)
        raise e
      ensure
        ::OperationCr::Instrumentation.pop
      end
    end

    def prepare
    end

    def before_execute
    end

    # Wraps `perform`'s return value before it leaves `.call`. The
    # default implementation returns the result unchanged.
    #
    # IMPORTANT: if you override `after_execute`, its return type MUST
    # match `typeof(perform)`. `Chain` infers chain-step return types
    # from `typeof(NextOp.allocate.perform)` (not `typeof(NextOp.call)`)
    # because the chain machinery needs a type that's stable at
    # compile time. Returning a different type here (e.g. wrapping into
    # a Result/envelope) will silently break composition: chained `.then`
    # blocks will be typed against the raw `perform` return, but the
    # actual head-op call returns your wrapped type. The mismatch
    # usually surfaces as a confusing "no overload matches" at the next
    # `.then`'s block boundary. To wrap results, use `.then { |r| ... }`
    # on the chain instead.
    def after_execute(result)
      result
    end

    def self.call(*pos, **kw)
      new(*pos, **kw).call
    end

    # Run with tracing on; format the resulting trace tree and return the
    # operation's result. Mirrors `typed_operation`'s `Operation.explain`.
    def self.explain(*pos, **kw)
      ::OperationCr::Instrumentation.explaining { call(*pos, **kw) }
    end
  end
end
