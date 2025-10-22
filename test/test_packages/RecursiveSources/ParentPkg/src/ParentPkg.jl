module ParentPkg

using ChildPkg

parent_value() = ChildPkg.child_value()

end
