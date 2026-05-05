require "../src/operation_cr"

class GreetUser < OperationCr::Operation
  param name : String
  param greeting : String = "Hello"

  def perform
    "#{greeting}, #{name}!"
  end
end

# `grete` is a typo for `greeting` -- should produce a compile error
# at THIS call site naming the operation, the bad key, and the valid keys.
GreetUser.with(grete: "Hi").call(name: "World")
