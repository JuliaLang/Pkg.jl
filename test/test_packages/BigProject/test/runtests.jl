# This file is a part of Julia. License is MIT: https://julialang.org/license

using Test
using Example
using BigProject

@test BigProject.f() == 1
