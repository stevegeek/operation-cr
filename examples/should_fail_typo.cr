# script/check-compile-errors asserts this file fails to compile with:
# expect-error: unknown param `grete` for GreetUser. Valid params: name, greeting
#
require "../src/operation_cr"

class GreetUser < OperationCr::Operation
  param name : String
  param greeting : String = "Hello"

  def perform
    "#{greeting}, #{name}!"
  end
end

# Same error that `should_fail_unknown_kw.cr` demonstrates: typo'd kwarg
# at `.with(...)` is now caught at compile time with a clear message that
# names the operation, the offending key, and the valid params.
GreetUser.with(grete: "Hi").call(name: "World")
