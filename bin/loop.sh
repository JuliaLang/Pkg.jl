#!/bin/bash

julia() {
    ~/julia/julia "$@"
}

slumber=120
metadata=~/.julia/v1.1/METADATA
registry=~/.julia/registries/General

while :
do
    echo Updating the General registry...
    git -C "$metadata" pull
    git -C "$registry" pull
    perl -i -ple 's/^uuid =/# uuid =/' Project.toml
    julia --project bin/update.jl
    perl -i -ple 's/^# uuid =/uuid =/' Project.toml
    git -C "$registry" add -A .
    git -C "$registry" commit -m 'automatic sync with METADATA'
    git -C "$registry" push origin master
    echo Sleeping for $slumber seconds...
    sleep $slumber
done
