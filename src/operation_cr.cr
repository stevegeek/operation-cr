module OperationCr
  VERSION = "0.3.0"
end

# Note: `./operation_cr/result` is intentionally NOT required here. The
# Result type is opt-in — see the file's top comment.
require "./operation_cr/step_value"
require "./operation_cr/instrumentation"
require "./operation_cr/operation"
require "./operation_cr/partially_applied"
require "./operation_cr/composition"
require "./operation_cr/curried"
require "./operation_cr/pipeline"
