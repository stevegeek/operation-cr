module OperationCr
  abstract class Operation
    macro inherited
      KW_PARAMS = {} of Nil => Nil

      macro finished
        __build_initialize
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
