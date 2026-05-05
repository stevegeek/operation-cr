macro probe(decl)
  {% puts "decl: #{decl.id}", "decl.class_name: #{decl.class_name}", "decl.value: #{decl.value}", "decl.value.class_name: #{decl.value.class_name}", "decl.value == nil: #{decl.value == nil}", "decl.value.is_a?(Nop): #{decl.value.is_a?(Nop)}" %}
end

probe name : String
probe greeting : String = "Hello"
