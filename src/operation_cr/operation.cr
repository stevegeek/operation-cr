module OperationCr
  abstract class Operation
    macro inherited
      # Ordered map of positional params: name => {type:, has_default:, default:}
      POSITIONAL_PARAMS = {} of Nil => Nil
      # Ordered map of keyword params: name => {type:, has_default:, default:}
      KW_PARAMS = {} of Nil => Nil

      macro finished
        __build_initialize
      end
    end

    macro __build_initialize
      {% pos_params = @type.constant("POSITIONAL_PARAMS") %}
      {% kw_params = @type.constant("KW_PARAMS") %}
      def initialize(
        {% for name, info in pos_params %}
          @{{name.id}} : {{info[:type]}}{% if info[:has_default] %} = {{info[:default]}}{% end %},
        {% end %}
        {% if kw_params.size > 0 %}
        *,
        {% for name, info in kw_params %}
          @{{name.id}} : {{info[:type]}}{% if info[:has_default] %} = {{info[:default]}}{% end %},
        {% end %}
        {% end %}
      )
        prepare
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
      getter {{decl.var.id}} : {{decl.type}}
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

    def self.call(*pos, **kw)
      new(*pos, **kw).call
    end

    def self.with(*pos, **kw)
      ::OperationCr::PartiallyApplied(self, typeof(pos), typeof(kw)).new(pos, kw)
    end
  end
end
