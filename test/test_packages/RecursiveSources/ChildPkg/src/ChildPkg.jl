module ChildPkg

using GrandchildPkg
using SiblingPkg

child_value() = GrandchildPkg.VALUE + SiblingPkg.offset()

end
