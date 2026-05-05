require "../src/operation_cr"

class GreetUser < OperationCr::Operation
  param name : String
  param greeting : String = "Hello"

  def perform
    "#{greeting}, #{name}!"
  end
end

GreetUser.with(grete: "Hi").call(name: "World")
