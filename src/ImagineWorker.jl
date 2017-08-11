__precompile__(true)

module ImagineWorker

using ImagineInterface, Unitful
using NIDAQ

global DEVICE_PREFIX = ""        

export _set_device

_set_device{T<:AbstractString}(dev::T) = global DEVICE_PREFIX = String(dev)

include("inputs.jl")
include("outputs.jl")

end #module