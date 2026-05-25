require "../src/operation_cr"

# Operation with only positional params
class Add < OperationCr::Operation
  positional_param a : Int32
  positional_param b : Int32

  def perform
    a + b
  end
end

# Operation with positional + keyword params, including defaults
class Greet < OperationCr::Operation
  positional_param name : String
  param greeting : String = "Hello"
  param punctuation : String = "!"

  def perform
    "#{greeting}, #{name}#{punctuation}"
  end
end

# Operation with optional positional (default)
class Repeat < OperationCr::Operation
  positional_param phrase : String
  positional_param times : Int32 = 2

  def perform
    Array.new(times, phrase).join(" ")
  end
end

puts Add.call(2, 3)                      # => 5
puts Greet.call("World")                 # => Hello, World!
puts Greet.call("World", greeting: "Hi") # => Hi, World!
puts Repeat.call("hi")                   # => hi hi
puts Repeat.call("hi", 4)                # => hi hi hi hi

# Partial application: bind positionals, finish later.
add5 = Add.with(5)
puts add5.call(10) # => 15

# Bind a positional and a keyword, finish with the remaining positional override.
shouter = Greet.with(greeting: "HEY", punctuation: "!!!")
puts shouter.call("Bob") # => HEY, Bob!!!

# Chain partial applications across positional and keyword args.
step1 = Greet.with("Carol")
step2 = step1.with(greeting: "Howdy")
puts step2.call # => Howdy, Carol!
