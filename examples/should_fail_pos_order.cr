# script/check-compile-errors asserts this file fails to compile with:
# expect-error: required positional_param 'b' cannot follow optional positional_param 'a'
#
require "../src/operation_cr"

class BadOrder < OperationCr::Operation
  positional_param a : Int32 = 1
  positional_param b : Int32

  def perform
    a + b
  end
end
