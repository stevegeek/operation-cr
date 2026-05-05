require "../src/operation_cr"

class GreetUser < OperationCr::Operation
  param name : String
  param greeting : String = "Hello"

  def perform
    "#{greeting}, #{name}!"
  end
end

# Missing required `name` — should be a compile error.
GreetUser.with(greeting: "Hi").call
