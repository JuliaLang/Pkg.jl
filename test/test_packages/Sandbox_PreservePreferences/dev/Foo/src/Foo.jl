module Foo

using Preferences

set!(key, value) = @set_preferences!(key=>value)
get(key) = @load_preference(key)

end # module
