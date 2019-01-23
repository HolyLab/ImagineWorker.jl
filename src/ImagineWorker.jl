module ImagineWorker

using ImagineInterface, Unitful, NIDAQ, Distributed

@static if !Sys.iswindows()
    @warn("This package only works on Windows")
end

@static if Sys.iswindows() && !isfile("C:\\Windows\\System32\\nicaiu.dll")
    error("nicaiu.dll not found. Is NIDAQmx installed?")
end

@static if Sys.iswindows() && isfile("C:\\Windows\\System32\\nicaiu.dll")
    using NIDAQ
    global DEVICE_PREFIX = ""        

    export _set_device,
		_record_analog_signals,
		_output_analog_signals

    _set_device(dev::T) where {T<:AbstractString} = global DEVICE_PREFIX = String(dev)

    include("inputs.jl")
    include("outputs.jl")
end


end #module
