require "../src/operation_cr"
# The Result type is opt-in. The core shard has none; this one require
# adds `Success` / `Failure`, teaches `Pipeline` to short-circuit, and
# teaches `Chain` the `and_then` method.
require "../src/operation_cr/result"

# Expected failures as values, instead of exceptions.
#
# `examples/pipeline.cr` shows the same order flow with exception-based
# failure handling. Compare the two: there, "quantity must be positive"
# is a `raise` that `on_failure` catches. Here it is a `Failure` a step
# returns, which the pipeline short-circuits on and `on_step_failure`
# translates. Exceptions still exist and still mean "something broke";
# they are no longer how a validated input reports being invalid.

# -- Result aliases --
# Crystal has no generic aliases, so there is no `Result(T)` type name:
# `alias Result(T) = Success(T) | Failure` does not even parse. Write the
# union, or name it per call site like this.

alias ValidationResult = OperationCr::Success(NamedTuple(validated: Bool)) | OperationCr::Failure
alias PriceResult = OperationCr::Success(NamedTuple(unit_price_cents: Int32)) | OperationCr::Failure
alias ChargeResult = OperationCr::Success(NamedTuple(charge_id: String)) | OperationCr::Failure

# -- Operations --
# A step may return a plain NamedTuple (as before) or
# `Success(NamedTuple) | Failure`. The pipeline merges the unwrapped
# NamedTuple of a Success, and stops at the first Failure.

class ValidateOrder < OperationCr::Operation
  param product_id : Int32
  param quantity : Int32

  def perform : ValidationResult
    errors = [] of OperationCr::Error
    errors << OperationCr::Error.new(:not_positive, "quantity", "got #{quantity}") unless quantity > 0
    errors << OperationCr::Error.new(:unknown, "product_id") unless product_id > 0

    # Failures combine, so one pass reports every bad input.
    return OperationCr::Failure.new(errors) unless errors.empty?
    OperationCr::Success.new({validated: true})
  end
end

class FetchPrice < OperationCr::Operation
  param product_id : Int32

  PRICES = {1 => 1500, 2 => 800, 3 => 250}

  def perform : PriceResult
    price = PRICES[product_id]?
    return OperationCr::Failure.new(:no_price, "product_id", "product #{product_id}") if price.nil?
    OperationCr::Success.new({unit_price_cents: price})
  end
end

# Steps that cannot fail stay exactly as they were: a plain NamedTuple.
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

  def perform : ChargeResult
    return OperationCr::Failure.new(:gateway_down, nil, "try again later") if customer_id == 999
    OperationCr::Success.new({charge_id: "ch_#{customer_id}_#{total_cents}"})
  end
end

# -- Pipeline --
# `on_step_failure` is separate from `on_failure`: the first handles a
# `Failure` a step returned, the second an exception a step raised. Both
# may be defined. Without `on_step_failure` the pipeline simply returns
# the `Failure` itself, and the return type becomes `context | Failure`.

class OrderPipeline < OperationCr::Pipeline
  step ValidateOrder
  step FetchPrice
  step ComputeTotal
  step :charge, ChargePayment

  before_step do |_ctx, step_name|
    puts "  [step: #{step_name}]"
  end

  on_step_failure do |failure, step_name|
    puts "  ✗ #{step_name} failed: #{failure.codes.inspect}"
    {ok: false, failed_at: step_name, codes: failure.codes}
  end
end

# -- Happy path --
puts "Happy path:"
result = OrderPipeline.call(product_id: 1, quantity: 3, customer_id: 42)
puts "  → #{result[:charge_id]?} (total: #{result[:total_cents]?}¢)"

puts ""

# -- Short-circuit: the first step fails, later steps never run --
puts "Invalid input (two errors at once, FetchPrice never runs):"
result = OrderPipeline.call(product_id: 0, quantity: 0, customer_id: 42)
puts "  → ok? #{result[:ok]?}, codes #{result[:codes]?.inspect}"

puts ""

# -- Short-circuit mid-way --
puts "Gateway down (fails at the last step):"
result = OrderPipeline.call(product_id: 1, quantity: 1, customer_id: 999)
puts "  → ok? #{result[:ok]?}, failed at #{result[:failed_at]?}"

puts ""

# -- Without a handler, the Failure is the pipeline's return value --
class BareOrderPipeline < OperationCr::Pipeline
  step ValidateOrder
  step FetchPrice
  step ComputeTotal
end

puts "No on_step_failure — exhaustive handling at the call site:"
bare = BareOrderPipeline.call(product_id: 7, quantity: 1)

# The union is exhaustive: drop the Failure branch and this stops
# compiling. In the success branch the context is a plain NamedTuple.
case bare
in OperationCr::Failure
  puts "  → failed: #{bare.first_error.code} (#{bare.first_error.detail})"
in NamedTuple
  puts "  → total #{bare[:total_cents]}¢"
end

puts ""

# -- Chains get `and_then` too --
# `.then` always runs its block, on the wrapped value. `.and_then` runs it
# on the unwrapped value, and skips it entirely on a Failure.
puts "Chain#and_then:"
chain = ValidateOrder.and_then(FetchPrice) { |_validated| {product_id: 2} }
puts "  → #{chain.call(product_id: 2, quantity: 1).inspect}"
puts "  → #{chain.call(product_id: 2, quantity: -1).inspect}"
