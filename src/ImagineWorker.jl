__precompile__(false)

module ImagineWorker

using ImagineInterface, Unitful

if is_windows() && isfile("C:\\Windows\\System32\\nicaiu.dll")
    using NIDAQ
    global DEVICE_PREFIX = ""        

    export _set_device

    _set_device{T<:AbstractString}(dev::T) = global DEVICE_PREFIX = String(dev)

    include("inputs.jl")
    include("outputs.jl")
end

end #module
