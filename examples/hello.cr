require "../src/operation_cr"

class GreetUser < OperationCr::Operation
  param name : String
  param greeting : String = "Hello"

  def perform
    "#{greeting}, #{name}!"
  end
end

puts GreetUser.call(name: "World")
puts GreetUser.call(name: "Alice", greeting: "Hi")

welcomer = GreetUser.with(greeting: "Welcome")
puts welcomer.call(name: "Bob")
