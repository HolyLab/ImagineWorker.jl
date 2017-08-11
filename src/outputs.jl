function write_analog(t::NIDAQ.AOTask, data::Matrix{Float64}; timeout::Float64=-1.0, wait_for_space = true)
    num_samples_per_chan::Int32 = size(data, 1)
    data = reshape(data, length(data))
    num_samples_per_chan_written = Int32[0]
    buf_space_free = Ref{UInt32}(1)
    if wait_for_space #the function for checking write space returns 0 if the task has not been started yet.
        while true
            NIDAQ.catch_error(NIDAQ.GetWriteSpaceAvail(t.th, buf_space_free))
            #NOTE: with usb-6002 devices there seems to be more space available than was set by NIDAQ.DAQmxCfgOutputBuffer.  Strange but eems harmless enough.
            if buf_space_free[] >= num_samples_per_chan
                break
            end
            sleep(0.2) #buf size is currently 1s worth of samples, so this shouldn't need to be changed unless that changes
        end
    end
    NIDAQ.catch_error(NIDAQ.WriteAnalogF64(t.th,
        num_samples_per_chan,
        reinterpret(Bool32, UInt32(false)),
        timeout,
        reinterpret(Bool32,NIDAQ.Val_GroupByChannel),
        pointer(data),
        pointer(num_samples_per_chan_written),
        reinterpret(Ptr{Bool32},C_NULL)))
    if num_samples_per_chan_written[1] != num_samples_per_chan
        error("Wrote $num_samples_per_chan_written samples instead of the $num_samples_per_chan samples requested")
    end
end
write_analog(t::NIDAQ.AOTask, data::Vector{Float64}; timeout::Float64=-1.0) = write_analog(t, reshape(data,(length(data),1)), timeout=timeout)

#Probably no need for two names.  Just make this and write_analog two implementations of a _write function
function write_digital(t::NIDAQ.DOTask, data::Matrix{UInt8}; timeout::Float64=-1.0, wait_for_space = true)
    error("Not yet implemented")
end
write_digital(t::NIDAQ.DOTask, data::Vector{UInt8}; timeout::Float64=-1.0) = write_digital(t, reshape(data,(length(data),1)), timeout=timeout)

#returns a DAQ task handle
function prepare_ao(coms, bufsz::Int, trigger_terminal::String)
    print("preparing DAQ for ao...\n")
    chns = map(daq_channel, coms)
    nsamps = length(first(coms))
    nchans = length(coms)
    usb_req_size = Ref{UInt32}(0)
    rig = rig_name(first(coms))
    if !in(split(DEVICE_PREFIX, "/")[1], NIDAQ.devices())
        error("Device $DEVICE_PREFIX not detected")
    end
    tsk = analog_output(DEVICE_PREFIX * chns[1])
    for i = 2:length(chns)
        analog_output(tsk, DEVICE_PREFIX * chns[i])
        setproperty!(tsk, DEVICE_PREFIX * chns[i], "Max", 10.0) #"/ao0:1", "Max", 10.0)
    end
    if rig == "dummy-6002"
        #note: default Xfer size seems to be 8000 bytes (4000 samples)
        NIDAQ.catch_error(NIDAQ.GetAOUsbXferReqSize(tsk.th, Vector{UInt8}(DEVICE_PREFIX * chns[1]), usb_req_size))
        #See article here http://digital.ni.com/public.nsf/allkb/B7B47F50F9813DFD862575890054EF7C
        usb_req_size = Ref{UInt32}(usb_req_size[] * UInt32(2))
        for i = 1:length(chns)
            print("    Set Usb transfer request size for AO\n")
            NIDAQ.catch_error(NIDAQ.SetAOUsbXferReqSize(tsk.th, Vector{UInt8}(DEVICE_PREFIX * chns[i]), usb_req_size[]))
        end
    end
    NIDAQ.catch_error(NIDAQ.CfgSampClkTiming(tsk.th,
            convert(Ref{UInt8},b""),
            Float64(ustrip(samprate(first(coms)))),
            NIDAQ.Val_Rising,
            NIDAQ.Val_FiniteSamps,
            UInt64(nsamps)))
    disallow_regen = Int32(10158) #default is allow regen (10097).  We want to disallow it (10158)
    NIDAQ.catch_error(NIDAQ.DAQmxSetWriteRegenMode(tsk.th, disallow_regen))
    #print("AO buffer size (nsamps): $bufsz\n")
    NIDAQ.catch_error(NIDAQ.DAQmxCfgOutputBuffer(tsk.th, UInt32(bufsz)))
    if trigger_terminal != "disabled"
        print("    setting up digital start trigger for analog output...\n")
        props = NIDAQ.getproperties(String(split(DEVICE_PREFIX, "/")[1]))
        terms = props["Terminals"][1]
        if !in("/" * DEVICE_PREFIX * trigger_terminal, terms)
            error("Terminal $trigger_terminal is does not exist.  Check valid terminals with NIDAQ.getproperties(dev)[\"Terminals\"]")
        end
        #The below three commands should be equivalent to call ing CfgDigEdgeStartTrig
        #NIDAQ.catch_error(NIDAQ.SetStartTrigType(tsk.th, NIDAQ.Val_DigEdge))
        #NIDAQ.catch_error(NIDAQ.SetDigEdgeStartTrigSrc(tsk.th, "/" * DEVICE_PREFIX * trigger_terminal))
        #NIDAQ.catch_error(NIDAQ.SetDigEdgeStartTrigEdge(tsk.th, NIDAQ.Val_Rising))
        NIDAQ.catch_error(NIDAQ.CfgDigEdgeStartTrig(tsk.th, convert(Ref{UInt8}, convert(Array{UInt8}, "/" * DEVICE_PREFIX * trigger_terminal)), NIDAQ.Val_Rising))
    end
    return tsk
end

function prepare_do(coms, bufsz::Int, trigger_terminal::String)
    error("Not yet implemented")
end

function _output_analog_signals{T<:ImagineSignal}(coms::AbstractVector{T}, samps_per_write::Int, trigger_terminal::String, ready_chan::RemoteChannel)
    if length(finddigital(coms)) != 0
        error("Please provide only analog ImagineSignals")
    end
    if !all(map(isoutput, coms))
        error("Please provide only output ImagineSignals")
    end
    tsk = prepare_ao(coms, 2*samps_per_write, trigger_terminal)
    nchans = length(coms)
    finished = false
    curstart = 1
    nsamps = length(first(coms))
    write_buffer = zeros(Float64, samps_per_write, nchans)
    write_incr = samps_per_write - 1
    wrote_once = false
    try
        while !finished
            curstop = curstart + write_incr
            if curstop >= nsamps
                finished = true
                curstop = min(nsamps, curstop)
            end
            nsamps_to_write = curstop - curstart + 1
            for i = 1:nchans
                write_buffer[1:nsamps_to_write, i] = ustrip(get_samples(coms[i], curstart, curstop; sampmap = :volts))
            end
            #now write to daq buffer
            if wrote_once
                write_analog(tsk, write_buffer[1:nsamps_to_write,:], timeout=-1.0)
            else
                write_analog(tsk, write_buffer[1:nsamps_to_write,:], timeout=-1.0, wait_for_space = false)
            end
            print("So far $curstop of $nsamps samples have been written...\n")
            curstart = curstop + 1
            if !wrote_once
                start(tsk)
                put!(ready_chan, myid())
                wrote_once = true
            end
        end
    catch
        clear(tsk)
        rethrow()
    end
    #print("Waiting for AO task to complete\n")
    NIDAQ.catch_error(NIDAQ.WaitUntilTaskDone(tsk.th, 2.0))
    stop(tsk)
    clear(tsk)
    return ImagineSignal[]
end

function _output_digital_signals{T>:ImagineSignal}(coms::AbstractVector{T}, samps_per_write::Int, trigger_terminal::String)
    if length(findanalog(coms)) != 0
        error("Please provide only digital ImagineSignals")
    end
    if !all(map(isoutput, coms))
        error("Please provide only output ImagineSignals")
    end
    tsk = prepare_ao(coms, 2*samps_per_write, trigger_terminal)
    nchans = length(coms)
    finished = false
    curstart = 1
    nsamps = length(first(coms))
    write_buffer = zeros(Float64, samps_per_write, nchans)
    write_incr = samps_per_write - 1
    wrote_once = false
    try
        while !finished
            curstop = curstart + write_incr
            if curstop >= nsamps
                finished = true
                curstop = min(nsamps, curstop)
            end
            nsamps_to_write = curstop - curstart + 1
            for i = 1:nchans
                write_buffer[1:nsamps_to_write, i] = ustrip(get_samples(coms[i], curstart, curstop; sampmap = :volts))
            end
            #now write to daq buffer
            if wrote_once
                write_digital(tsk, write_buffer[1:nsamps_to_write,:], timeout=-1.0)
            else
                write_digital(tsk, write_buffer[1:nsamps_to_write,:], timeout=-1.0, wait_for_space = false)
            end
            curstart = curstop + 1
            if !wrote_once
                start(tsk)
                set_ready()
                wrote_once = true
            end
        end
    catch
        clear(tsk)
        rethrow()
    end
    NIDAQ.WaitUntilTaskDone(tsk.th, -1.0) #wait forever
    stop(tsk)
    clear(tsk)
    return myid()
end

0 #Without this zero, the (fetched) remotecall that includes this file will return the _ttl_pulse function and cause an error.  Instead this makes it return 0
