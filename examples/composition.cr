require "../src/operation_cr"

# Sequential composition with `.then`. The result of one operation flows into
# the next via an explicit transformer block (no implicit "spread" magic --
# Crystal's static typing makes that brittle, so we keep the wiring honest).

class Double < OperationCr::Operation
  param x : Int32

  def perform : Int32
    x * 2
  end
end

class Stringify < OperationCr::Operation
  param value : Int32

  def perform : String
    "result=#{value}"
  end
end

class Shout < OperationCr::Operation
  param message : String

  def perform : String
    message.upcase + "!"
  end
end

# --- Two-op chain ---
# Block converts Double's Int32 result into the kwargs NamedTuple Stringify
# expects. The chain itself is callable with Double's kwargs.
chain = Double.then(Stringify) { |r| {value: r} }
puts chain.call(x: 21)
# => result=42

# --- Three-op chain ---
chain3 = Double
  .then(Stringify) { |r| {value: r} }
  .then(Shout) { |s| {message: s} }
puts chain3.call(x: 21)
# => RESULT=42!

# --- Block-only transform (.then with no second op) ---
# Like `.transform` in the Ruby gem -- just maps the value forward.
inc = Double.then { |r| r + 1 }
puts inc.call(x: 10)
# => 21

# --- Mixing transforms and operations ---
mixed = Double
  .then(Stringify) { |r| {value: r} }
  .then { |s| s + " woo" }
puts mixed.call(x: 5)
# => result=10 woo

# --- Partial application of the head's kwargs ---
# Chains support `.with` similarly to operations.
preset = chain.with(x: 7)
puts preset.call
# => result=14
