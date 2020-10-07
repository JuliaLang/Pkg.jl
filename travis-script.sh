#!/bin/bash

if [[ -a .git/shallow ]]; then git fetch --unshallow; fi
julia test/pkg-uuid.jl
julia --project -e 'using UUIDs; write("Project.toml", replace(read("Project.toml", String), r"uuid = .*?\n" =>"uuid = \"$(uuid4())\"\n"));'
try_count=0
while [ $try_count != 2 ]; do
    julia --project --check-bounds=yes -e 'import Pkg; Pkg.build(); Pkg.test(; coverage=true)'
    if [ $? = 0 ]; then exit 0; fi
    try_count = `expr $try_count + 1`
    sleep 60
done
exit 1
