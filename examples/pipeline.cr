require "../src/operation_cr"

# Declarative multi-step composition with `OperationCr::Pipeline`.
#
# Compared to the `.then` chain shape in `composition.cr`, a Pipeline:
#   - Reads top-to-bottom as a list of steps (no `.then(...) { |r| {...} }` glue)
#   - Auto-merges each step's NamedTuple return into a growing context
#   - Has `before_step` and `on_failure` hooks for cross-cutting concerns
#
# This example mirrors a small order-processing flow.

# -- Operations --
# Each operation declares its kwarg inputs as `param`s and returns a
# NamedTuple. Pipeline slices the inputs from the context and merges the
# return into it. Operations are independently `.call`-able for unit tests.

class ValidateOrder < OperationCr::Operation
  param product_id : Int32
  param quantity : Int32

  def perform : NamedTuple(validated: Bool)
    raise "quantity must be positive" unless quantity > 0
    raise "unknown product" unless product_id > 0
    {validated: true}
  end
end

class FetchPrice < OperationCr::Operation
  param product_id : Int32

  PRICES = {1 => 1500, 2 => 800, 3 => 250}

  def perform : NamedTuple(unit_price_cents: Int32)
    price = PRICES[product_id]? || raise "no price for product #{product_id}"
    {unit_price_cents: price}
  end
end

class ComputeTotal < OperationCr::Operation
  param quantity : Int32
  param unit_price_cents : Int32

  def perform : NamedTuple(total_cents: Int32)
    {total_cents: quantity * unit_price_cents}
  end
end

class ChargePayment < OperationCr::Operation
  param customer_id : Int32
  param total_cents : Int32

  def perform : NamedTuple(charge_id: String)
    raise "payment gateway down" if customer_id == 999
    {charge_id: "ch_#{customer_id}_#{total_cents}"}
  end
end

class SendConfirmation < OperationCr::Operation
  param customer_id : Int32
  param charge_id : String

  def perform : NamedTuple
    puts "  → emailing customer #{customer_id} (charge #{charge_id})"
    NamedTuple.new # void steps return empty NamedTuple
  end
end

# -- Pipeline --
# Subclass `OperationCr::Pipeline`, declare steps in order, add hooks.
#
# `before_step` fires before every step with the current context + step
# name. Useful for status updates, logging, or instrumentation that
# doesn't belong inside the operations themselves.
#
# `on_failure` fires when any step raises. The block's return value
# becomes the pipeline's result.

class OrderPipeline < OperationCr::Pipeline
  step ValidateOrder
  step FetchPrice
  step ComputeTotal
  step ChargePayment
  step :notify, SendConfirmation # explicit name override

  before_step do |_ctx, step_name|
    puts "  [step: #{step_name}]"
  end

  on_failure do |ex, step_name|
    puts "  ✗ failed at #{step_name}: #{ex.message}"
    {ok: false, failed_at: step_name, error: ex.message}
  end
end

# -- Happy path --
puts "Happy path:"
result = OrderPipeline.call(
  product_id: 1,
  quantity: 3,
  customer_id: 42,
)
puts "  → #{result[:charge_id]?} (total: #{result[:total_cents]?}¢)"

puts ""

# -- Failure path: invalid input is caught by on_failure --
puts "Failure path (bad quantity):"
result = OrderPipeline.call(
  product_id: 1,
  quantity: 0,
  customer_id: 42,
)
puts "  → ok? #{result[:ok]?}, failed at #{result[:failed_at]?}"

puts ""

# -- Failure path: payment gateway down --
puts "Failure path (gateway down):"
result = OrderPipeline.call(
  product_id: 1,
  quantity: 1,
  customer_id: 999,
)
puts "  → ok? #{result[:ok]?}, failed at #{result[:failed_at]?}"

puts ""

# -- Introspection --
puts "Pipeline steps: #{OrderPipeline.step_names.inspect}"

# -- Unit-test a single operation in isolation --
# Operations are independently callable; no pipeline state needed.
puts ""
puts "Unit-testing ComputeTotal directly:"
puts "  → #{ComputeTotal.call(quantity: 5, unit_price_cents: 300).inspect}"
