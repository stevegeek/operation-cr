require "../src/operation_cr"

class BadOrder < OperationCr::Operation
  positional_param a : Int32 = 1
  positional_param b : Int32

  def perform
    a + b
  end
end
