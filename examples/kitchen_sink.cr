require "../src/operation_cr"

# Exercises every feature of the shard: positional + keyword params,
# defaults, lifecycle, partial application, and .then composition.

class Add < OperationCr::Operation
  positional_param a : Int32
  positional_param b : Int32 = 0
  param multiplier : Int32 = 1

  def perform : Int32
    (a + b) * multiplier
  end
end

class Format < OperationCr::Operation
  param value : Int32
  param prefix : String = "result"

  def perform : String
    "#{prefix}=#{value}"
  end
end

class Shout < OperationCr::Operation
  param text : String

  def perform : String
    text.upcase + "!"
  end
end

# Direct call with positional + keyword
puts Add.call(2, 3, multiplier: 10)         # => 50

# Partial application of mixed positional + keyword
preset = Add.with(7, multiplier: 2)
puts preset.call                             # => 14
puts preset.call(3)                          # => 20

# Three-op chain over the whole shard, head op uses positional + keyword.
pipeline = Add
  .then(Format) { |n| {value: n} }
  .then(Shout) { |s| {text: s} }

puts pipeline.call(4, 5, multiplier: 3)      # => RESULT=27!

# Chain partial application also threads positional + keyword.
preset_pipeline = pipeline.with(10, multiplier: 2)
puts preset_pipeline.call(5)                 # => RESULT=30!
