module OperationCr
  # A declarative DSL for composing operations into a sequential pipeline.
  #
  # Each `step` runs an `OperationCr::Operation` in order. The operation's
  # kwarg params are sliced from a growing `context` NamedTuple, and the
  # operation's `perform` return value (which must be a `NamedTuple`) is
  # merged back into the context for subsequent steps. For steps that don't
  # contribute to context (pure side-effect operations), return
  # `NamedTuple.new`.
  #
  # Failure handling is exception-based by default (matching Crystal's
  # idioms). Define `on_failure` to catch any exception raised by a step and
  # translate it — the handler's return value becomes the pipeline's return
  # value.
  #
  # With the opt-in Result module (`require "operation_cr/result"`) a step
  # may instead *return* an `OperationCr::Failure`, which stops the pipeline
  # and is handled by the separate `on_step_failure` hook. See
  # `__build_pipeline_call` and `on_step_failure` below.
  #
  # ```
  # class MyPipeline < OperationCr::Pipeline
  #   step CloneRepo
  #   step ParseShardYml
  #   step BuildTarball
  #
  #   on_failure do |ex, step_name|
  #     Log.error(exception: ex) { "Pipeline failed at #{step_name}" }
  #     nil
  #   end
  # end
  #
  # MyPipeline.call(repo_url: "https://…", git_ref: "main")
  # ```
  #
  # ## Context flow
  #
  # The initial context is whatever kwargs are passed to `.call`. Each
  # step's `perform` return NamedTuple is merged in. Subsequent steps see
  # the union of all prior keys.
  #
  # If a step needs a key that hasn't been added yet, you'll get a
  # compile-time "missing key" error — the macro emits explicit per-key
  # extraction from the context.
  #
  # ## Step return values
  #
  # `step Op` requires `Op#perform` to return a `NamedTuple` — or, with the
  # opt-in Result module, a `Success(NamedTuple) | Failure`, whose Success
  # payload is unwrapped before merging. For void operations that don't
  # contribute to context, return `NamedTuple.new`. Bare-value returns
  # (`String`, `Int32`, etc.) are not compatible — wrap in a single-key
  # NamedTuple at the operation boundary.
  #
  # Key collisions: if two steps return the same key, the later step's
  # value wins (standard `NamedTuple#merge` semantics).
  #
  # ## Step operations
  #
  # Step operations must declare their inputs via `param :foo, T` (kwargs).
  # `positional_param` is rejected at compile time — there's no positional
  # context to extract from.
  #
  # ## Subclassing
  #
  # Pipelines are class-level constructs. Define a subclass per pipeline
  # and accumulate `step`s + an optional `on_failure` block. The pipeline
  # builds itself in `macro finished`.
  #
  # **Pipelines do not inherit.** Subclassing a Pipeline subclass is
  # rejected at compile time — the per-subclass `PIPELINE_STEPS`
  # accumulator wouldn't carry parent steps, leading to silently dropped
  # hooks. Subclass `OperationCr::Pipeline` directly.
  abstract class Pipeline
    macro inherited
      {% if @type.superclass != ::OperationCr::Pipeline %}
        {% raise "#{@type}: pipelines do not inherit. Subclass OperationCr::Pipeline directly rather than a Pipeline subclass — accumulating steps/hooks across an inheritance chain isn't supported." %}
      {% end %}

      # Compile-time accumulator: each entry is {operation_class, name}.
      PIPELINE_STEPS = [] of Nil
      # Set to true if the subclass defines an `on_failure` handler.
      HAS_FAILURE_HANDLER = [false]
      # Set to true if the subclass defines a `before_step` hook.
      HAS_BEFORE_STEP_HOOK = [false]
      # Set to true if the subclass defines an `on_step_failure` handler.
      HAS_STEP_FAILURE_HANDLER = [false]

      macro finished
        __build_pipeline_call
      end
    end

    # Add an operation as the next step in the pipeline.
    #
    # `name` defaults to the operation's class basename underscored (e.g.
    # `Publish::Operations::CloneRepo` → `:clone_repo`) and is passed to
    # `on_failure` for diagnostics.
    macro step(operation_class)
      {% PIPELINE_STEPS << {operation_class: operation_class, name: operation_class.stringify.split("::").last.underscore} %}
    end

    # Add an operation as the next step, with an explicit name for
    # diagnostics / `on_failure` step_name.
    macro step(name, operation_class)
      {% PIPELINE_STEPS << {operation_class: operation_class, name: name.id.stringify} %}
    end

    # Define a failure handler. The block receives the raised exception
    # and the step's name (Symbol). The block's return value becomes the
    # pipeline's return value. To re-raise, the block can `raise ex`.
    #
    # Without `on_failure`, exceptions propagate to the caller unchanged.
    # Calling `on_failure` more than once in a single Pipeline subclass is
    # rejected at compile time.
    macro on_failure(&block)
      {% if HAS_FAILURE_HANDLER[0] %}
        {% raise "#{@type}: on_failure may only be defined once per pipeline. The second definition would silently overwrite the first." %}
      {% end %}
      {% HAS_FAILURE_HANDLER[0] = true %}

      private def self.__pipeline_on_failure(%ex : ::Exception, %step_name : ::Symbol)
        {{ block.args[0] }} = %ex
        {{ block.args[1] }} = %step_name
        {{ block.body }}
      end
    end

    # Define a handler for a step that returns an `OperationCr::Failure`
    # (the opt-in Result module — `require "operation_cr/result"`).
    #
    # The block receives the `Failure` and the step's name (Symbol); its
    # return value becomes the pipeline's return value. Without it, the
    # `Failure` itself is returned.
    #
    # This is deliberately separate from `on_failure`, which is
    # exception-based. A Result failure is an expected outcome the step
    # chose to return, not a raised exception, and the two carry different
    # payloads (`OperationCr::Failure` vs `Exception`). Routing one into
    # the other would force a fake exception on one handler and a lie in
    # the other's signature. A pipeline may define both.
    #
    # Calling `on_step_failure` more than once in a single Pipeline
    # subclass is rejected at compile time.
    macro on_step_failure(&block)
      {% if HAS_STEP_FAILURE_HANDLER[0] %}
        {% raise "#{@type}: on_step_failure may only be defined once per pipeline. The second definition would silently overwrite the first." %}
      {% end %}
      {% HAS_STEP_FAILURE_HANDLER[0] = true %}

      private def self.__pipeline_on_step_failure(%failure : ::OperationCr::Failure, %step_name : ::Symbol)
        {{ block.args[0] }} = %failure
        {{ block.args[1] }} = %step_name
        {{ block.body }}
      end
    end

    # Define a hook that runs before each step. Block receives the current
    # context (NamedTuple of the merged shape up to this point) and the
    # upcoming step's name (Symbol). Useful for status updates, logging,
    # or per-step instrumentation that needs to happen between steps without
    # putting the side effect inside the operation itself.
    #
    # **Type-checking caveat:** because the context's NamedTuple shape grows
    # as the pipeline progresses, the block's `ctx` parameter sees the union
    # of every step's context type. Use `ctx[:key]?` (nilable lookup) for
    # keys that only exist at some steps; bare `ctx[:key]` only compiles at
    # a step where `:key` is guaranteed present.
    #
    # The hook's return value is discarded. To abort the pipeline from a
    # hook, raise an exception (caught by `on_failure` if defined).
    #
    # Calling `before_step` more than once in a single Pipeline subclass is
    # rejected at compile time.
    macro before_step(&block)
      {% if HAS_BEFORE_STEP_HOOK[0] %}
        {% raise "#{@type}: before_step may only be defined once per pipeline. The second definition would silently overwrite the first." %}
      {% end %}
      {% HAS_BEFORE_STEP_HOOK[0] = true %}

      private def self.__pipeline_before_step(%ctx, %step_name : ::Symbol) : ::Nil
        {{ block.args[0] }} = %ctx
        {{ block.args[1] }} = %step_name
        {{ block.body }}
        nil
      end
    end

    # Generated at `macro finished` time after all `step` and hook macros
    # have run.
    #
    # The running context is held in a single `%ctx` local that's reassigned
    # after each step's `merge`. Crystal's flow-sensitive type inference
    # tracks the growing NamedTuple shape across reassignments correctly
    # (verified on Crystal 1.20.1) — distinct vars per step are unnecessary.
    #
    # Operations must return a `NamedTuple` (use `NamedTuple.new` for void
    # operations), or — with the opt-in Result module — a
    # `Success(NamedTuple) | Failure`. Positional params are rejected with
    # a clear compile error.
    #
    # ## Result short-circuiting
    #
    # When `operation_cr/result` is loaded, each step is followed by a
    # `is_a?(Failure)` guard that returns early. The guard is emitted
    # unconditionally for every step, including steps that can never
    # fail: Crystal prunes a statically-unreachable `is_a?` branch, so a
    # pipeline whose steps all return plain NamedTuples keeps its exact
    # pre-0.3.0 return type (verified by a `typeof` assertion in
    # `spec/pipeline_result_spec.cr`). Short-circuiting therefore needs no
    # opt-in macro.
    #
    # The guard is skipped entirely when `OperationCr::Failure` is not
    # defined — otherwise the emitted `is_a?(::OperationCr::Failure)` would
    # name a constant that does not exist, and every plain pipeline in a
    # program that never opted in would fail to compile. `macro finished`
    # runs after all `require`s, so this check sees the final program.
    macro __build_pipeline_call
      # Validate that no step operation uses positional_param.
      {% for step in PIPELINE_STEPS %}
        {% op_resolved = step[:operation_class].resolve %}
        {% if op_resolved.constant("POSITIONAL_PARAMS").size > 0 %}
          {% raise "Pipeline step #{op_resolved} declares positional_param; pipelines pass kwargs only. Change to `param :name, T` (kwarg form)." %}
        {% end %}
      {% end %}

      {% result_module_loaded = ::OperationCr.has_constant?("Failure") %}

      {% if HAS_STEP_FAILURE_HANDLER[0] && !result_module_loaded %}
        {% raise "#{@type}: on_step_failure needs the opt-in Result module, otherwise no step can ever return a Failure. Add: require \"operation_cr/result\"." %}
      {% end %}

      def self.call(**initial_context)
        %ctx = initial_context

        {% for step in PIPELINE_STEPS %}
          {% op = step[:operation_class] %}
          {% op_resolved = op.resolve %}
          {% kw_params = op_resolved.constant("KW_PARAMS") %}

          %ctx = begin
            {% if HAS_BEFORE_STEP_HOOK[0] %}
              __pipeline_before_step(%ctx, :{{ step[:name].id }})
            {% end %}

            %step_result = {{ op }}.call(
              {% for key in kw_params.keys %}
                {{ key.id }}: %ctx[{{ key }}],
              {% end %}
            )

            {% if result_module_loaded %}
              if %step_result.is_a?(::OperationCr::Failure)
                {% if HAS_STEP_FAILURE_HANDLER[0] %}
                  return __pipeline_on_step_failure(%step_result, :{{ step[:name].id }})
                {% else %}
                  return %step_result
                {% end %}
              end
            {% end %}

            %ctx.merge(::OperationCr.step_value(%step_result))
          rescue %ex
            {% if HAS_FAILURE_HANDLER[0] %}
              return __pipeline_on_failure(%ex, :{{ step[:name].id }})
            {% else %}
              raise %ex
            {% end %}
          end
        {% end %}

        %ctx
      end

      # Introspection: returns the names of all steps in declaration order.
      def self.step_names : ::Array(::Symbol)
        [
          {% for step in PIPELINE_STEPS %}
            :{{ step[:name].id }},
          {% end %}
        ] of ::Symbol
      end
    end
  end
end
