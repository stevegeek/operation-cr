module OperationCr
  abstract class Operation
    macro inherited
      KW_PARAMS = {} of Nil => Nil

      macro finished
        __build_initialize
        __build_with
      end
    end

    macro __build_initialize
      {% kw_params = @type.constant("KW_PARAMS") %}
      def initialize(
        *,
        {% for name, info in kw_params %}
          @{{name.id}} : {{info[:type]}}{% if info[:has_default] %} = {{info[:default]}}{% end %},
        {% end %}
      )
        prepare
      end
    end

    # Generates a per-subclass `.with` that validates kwarg keys at compile
    # time against the subclass's `KW_PARAMS`. Unknown keys raise a clear
    # error at the user's call site rather than triggering a confusing
    # "missing argument" error deep inside `partially_applied.cr`.
    #
    # The escaped (`\{% %}`) blocks survive this outer macro expansion and
    # land in the generated method body, where they run at method
    # instantiation time -- once per distinct kwargs shape `T`.
    macro __build_with
      def self.with(**args : **T) forall T
        \{% for key in T.keys %}
          \{% if !@type.constant("KW_PARAMS").keys.map(&.id.stringify).includes?(key.id.stringify) %}
            \{% raise "unknown param `#{key.id}` for #{@type}. Valid params: #{@type.constant("KW_PARAMS").keys.map(&.id).join(", ").id}" %}
          \{% end %}
        \{% end %}
        ::OperationCr::PartiallyApplied(self, T).new(args)
      end
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
      getter {{decl.var.id}} : {{decl.type}}
    end

    abstract def perform

    def call
      before_execute
      result = perform
      after_execute(result)
    end

    def prepare
    end

    def before_execute
    end

    def after_execute(result)
      result
    end

    def self.call(**args)
      new(**args).call
    end

    def self.with(**args)
      ::OperationCr::PartiallyApplied(self, typeof(args)).new(args)
    end
  end
end
