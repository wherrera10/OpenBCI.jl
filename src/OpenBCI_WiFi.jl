#=
OpenBCI_WiFi.jl
@Author: William Herrera
@Version: 0.011
@Copyright William Herrera, 2018
@Created: 16 Jan 2018
@Purpose: EEG WiFi routines using OpenBCI Arduino hardware
=#

module OpenBCI_WiFi
using Logging
using EDFPlus
using Requests
using JSON
import Requests: get, post, get_streaming


"""
See http://docs.openbci.com/Hardware/03-Cyton_Data_Format#cyton-data-format-binary-format
The ganglion data is same as cyton when hooked to wifi board except that only the
first 4 channels have data, with others specified to be 0
"""
const SAMPLERATE = 250.0         # Hz, the default fs for ganglion
const STARTBYTE = 0xA0           # start of 33 byte data packet
const ENDBYTE = 0xC0             # end of 33 byte data packet
const DEFAULT_STREAM_PORT = 5020 # streaming port, obscure zenginkyo-1 is 5020


# So microvolts per digital unit is 15686 / 8388607 = 0.001869917138805
const INT12MINIMUM = -2048
const INT12MAXIMUM =  2047
const INT24MINIMUM = -8388608    # digital minimum
const INT24MAXIMUM =  8388607    # digital maximum
const CYTONPHYSICALMINIMUM = -187500
const CYTONPHYSICALMAXIMUM =  187500
const GANGLIONPHYSICALMINIMUM = -15686  # microvolts
const GANGLIONPHYSICALMAXIMUM =  15686  # microvolts


# accelerometer conversion factor
const scale_fac_accel_G_per_count = 0.032  # 0.032 G or 32 mG per accelerometer unit


# Commands for in SDK http://docs.openbci.com/software/01-Open BCI_SDK
const command_stop = "s"
const command_startText = "x"
const command_startBinary = "b"
const command_startBinary_wAux = "n"
const command_startBinary_4chan = "v"
const command_activateFilters = "F"
const command_deactivateFilters = "g"
const command_deactivate_channel = ["1", "2", "3", "4", "5", "6", "7", "8"]
const command_activate_channel = ["q", "w", "e", "r", "t", "y", "u", "i"]
const command_activate_leadoffP_channel = ["!", "@", "#", "\$", "%", "^", "&", "*"]    # shift + 1-8
const command_deactivate_leadoffP_channel = ["Q", "W", "E", "R", "T", "Y", "U", "I"]  # letters (plus shift) right below 1-8
const command_activate_leadoffN_channel = ["A", "S", "D", "F", "G", "H", "J", "K"]    # letters (plus shift) below the letters below 1-8
const command_deactivate_leadoffN_channel = ["Z", "X", "C", "V", "B", "N", "M", "<"]  # letters (plus shift) below the letters below the letters below 1-8
const command_biasAuto = "`"
const command_biasFixed = "~"
const sratecommands = Dict(25600 =>'0', 12800 =>'1', 6400 =>'2', 3200 =>'3', 1600=>'4', 800=>'5', 400=>'6', 200=>'7')


""" Send a command to the OpenBCI harware via the WiFI http server POST /command JSON interface """
function postwrite(server, command)
    resp = post("$server/command"; json=Dict("command"=>command))
    if statuscode(resp) == 200
        info("command was $command, response was $(readstring(resp))")
    else
        warn("Got status $(statuscode(resp)), failed to get proper response from $server after command $command")
    end
end


""" The functions below all are specific calls to the postwrite function above ""
stop(server) = postwrite(server,command_stop)           # stop streaming "s"
softreset(server) = postwrite(server, "v")              # reset peripherals only
start(server) = postwrite(server, command_startBinary)  # 'b', binary streaming should now start
getfs(server) = postwrite(server, "~~")                 # reply is sample rate
setnonstandardfs(server, srate=200) = postwrite(server, sratecommands[srate])
getregisters(server) = postwrite(server, "?")
enablechannels(server, chan=[1,2,3,4]) = for i in chan postwrite(server, b"qwer"[i]) end
disablechannel(server, chan) = postwrite(server,chan)
startsquarewave(server) = postwrite(server, "[")
stopsquarewave(server) = postwrite(server, "]")
startimpedancetest(server) = postwrite(server, "z")
stopimpedancetest(server) = postwrite(server, "Z")
startaccelerometer(server) = postwrite(server, "n")
stopaccelerometer(server) = postwrite(server, "N")
startSDlogging(server) = postwrite(server, "J")         # up to 4 hrs unless stopped!
stopSDlogging(server) = postwrite(server, "j")          # one hour max default
attachshield(server) = postwrite(server, "{")
detachshield(server) = postwrite(server, "}")
resetshield(server) = postwrite(server,";")


""" TODO: run impedence test. This is not well documented, will need to specify further later """
function runimpedancetest(serveraddress)
    startimpedancetest(serveraddress)
    startimpedancetest(serveraddress)
end


"""
    asyncsocketserver(serveraddress, portnum, packetchannel, timeout)
Server task, run in separate task, gets stream of packets from the OpenBCI Wifi hardware 
and sends back to main process via a channel
serveraddress: in form of "http://111.222.333/" (used to restert if error)
portnum: our port number the OpenBCI Wifi will connect to
timeout: how long to wait before we decide to redo the socket
"""
function asyncsocketserver(serveraddress, portnum, packetchannel, timeout)
    timer = time()
    sequentialtimeouts = 0
    numberofgets = 1
    try
        info("Entered server async code")
        while true
            server = listen(IPv4(0), portnum)
            wifisocket = accept(server)
            info("socket service connected to ganglion board")
            bytes = b""
            while isopen(wifisocket)
                bytes = vcat(bytes,read(wifisocket,33))
                if length(bytes) >= 33
                    if bytes[1] == 0xA0 # in sync?
                        put!(packetchannel, bytes[1:33])
                        bytes = bytes[34:end]
                        timer = time()
                        sequentialtimeouts = 0
                    elseif (top = findfirst(x->x==0xA0, bytes)) > 0
                        info("sync: dropping bytes above position $top")
                        bytes = bytes[top:end]
                    else
                        info("sync: dumping buffer")
                        bytes = b""
                    end
                else
                    if time() - timer > timeout
                        sequentialtimeouts += 1
                        break
                    end
                    yield()
                    sleep(0.01)
                end
            end
            # if we got here we may need to do a restart, but try a new get also
            if sequentialtimeouts > 2
                warn("connection timeout, restarting connection")
            end
            numberofgets += 1
            info("Redoing get for binary stream, will now have done get $numberofgets times")
            get("$serveraddress/stream/start")
        end
    catch y
        info("Caught exception $y")
        # either error or the channel to process the packets has been closed
        info("Exiting WiFi streaming task")
    end
end


"""
    rawganglionboard
Implement a raw OpenBCI WiFI shield connection.
Args:
ipnum            the ip number of the WiFi shield
portnum          the port number to which the shield will stream data
timeout          seconds for a timeout error
fs               sampling rate, usually 250 == SAMPLERATE
latency          latency in microseconds, time between packets, default 15 msec
locallogging     true if loglevel is to be info rather than warn
logSD            true if should log to SD card
useaccelerometer true if accelerometer data to be sent
impedancetest    true if impedance check to be done
maketestwave     true if test signal to be gererated
"""
function rawganglionboard(ip_board, ip_ours; portnum=DEFAULT_STREAM_PORT, timeout=5,
                           fs=250, latency=15000, locallogging=false, logSD=false,
                           useaccelerometer=false, impedancetest=false, maketestwave=false)
    if locallogging
        Logging.configure(level=INFO)
        info("--- Logging starting session ---")
    else
        Logging.configure(level=WARNING)
    end
    serveraddress = "http://$ip_board"
    resp = get("$serveraddress/board", timeout=timeout)
    if statuscode(resp) == 200
        # expect: {"board_connected": true, "board_type": "string",
        # "gains": [ null ], "num_channels": 0}
        sysinfo = Requests.json(resp)
        info("board reports $sysinfo")
        if sysinfo["num_channels"] != 4
            warn("board reports $(sysinfo["num_channels"]) channels not 4")
        end
    end
    # It's important to start the server process before we set up the TCP port
    # so that the board will find the socket for the connection right away.
    packetchannel = Channel(1280)
    @async(asyncsocketserver(serveraddress, portnum, packetchannel, timeout))

    # Now we set up the TCP port connection from the board to our service
    jso = Dict("ip"=>ip_ours, "port"=>portnum, "output"=>"raw", "latency"=>latency)
    resp = post("$serveraddress/tcp"; json=jso)
    info("sending json")
    if statuscode(resp) == 200
        tcpinfo = Requests.json(resp)
        if tcpinfo["connected"]
            info("Wifi shield TCP server, command connection established, info is $(readstring(resp))")
        else
            throw("TCP connection failure with $serveraddress")
        end
    else
        warn("tcp config error status code: $(statuscode(resp))")
    end
    if fs != 250 && fs in [1600, 800, 400 , 200]
        setnonstandardfs(serveraddress, fs)
    end
    if logSD
        startSDlogging(serveraddress)
    end
    if useaccelerometer
        startaccelerometer(serveraddress)
    else
        stopaccelerometer(serveraddress)
    end
    info("completed config of ganglion")
    # if impedance test, do that for 15 seconds, store in records
    if impedancetest
        runimpedancetest(serveraddress)
    end
    if maketestwave
        startsquarewave(serveraddress)
    end
    # now do data collection as a task that will terminate only when we tell it later
    # stop via exception when the channel is closed
    info("asking for stream")
    get("$serveraddress/stream/start")
    # return the channel where the data packets will be stacked
    packetchannel
end


function startBDFPluswritefile(signalchannels::Int, patientID="", recording="", patientcode="",
                               gender="", birthdate="", patientname="", patient_additional="",
                               admincode="", technician="", equipment="", recording_additional="")
    bdfh = BEDFPlus()

    bdfh.writemode = true
    bdfh.version = "$(EDFPlus.version())"
    bdfh.edf = false
    bdfh.edfplus = false
    bdfh.bdf = false
    bdfh.bdfplus = true
    bdfh.discontinuous = false
    bdfh.filetype = EDFPlus.BDFPLUS
    bdfh.channelcount = signalchannels + 1  # add 1 for the annotation channel
    bdfh.patient = patientID
    bdfh.recording = recording
    bdfh.patientcode = patientcode
    bdfh.gender = gender
    bdfh.birthdate = birthdate
    bdfh.patientname = patientname
    bdfh.patient_additional = patient_additional
    bdfh.admincode = admincode
    bdfh.technician = technician
    bdfh.equipment = equipment
    bdfh.recording_additional = recording_additional

    bdfh.annotationchannel = bdfh.channelcount
    bdfh
end


"""
    startBDFPluswritefile(signalchannels, json_idfile)
json_idfile is a file containing JSON formatted patient information.
"""
function startBDFPluswritefile(json_idfile::String, signalcount::Int=4)
    patientID=""
    recording=""
    patientcode=""
    gender=""
    birthdate=""
    patientname=""
    patient_additional=""
    admincode=""
    technician=""
    equipment=""
    recording_additional=""
    try
        jfh = open(json_idfile, "r")
        dict = JSON.parse(readstring(jfh))
        close(jfh)
        info("Using patient file ID information: $dict")
        if haskey(dict, "patientID") patientID = dict["patientID"] end
        if haskey(dict, "recording") recording = dict["recording"] end
        if haskey(dict, "patientcode") patientcode = dict["patientcode"] end
        if haskey(dict, "gender") gender = dict["gender"] end
        if haskey(dict, "birthdate") birthdate = uppercase(dict["birthdate"]) end
        if haskey(dict, "patientname") patientname = dict["patientname"] end
        if haskey(dict, "patient_additional") patient_additional = dict["patient_additional"] end
        if haskey(dict, "admincode") admincode = dict["admincode"] end
        if haskey(dict, "technician") technician = dict["technician"] end
        if haskey(dict, "equipment") equipment = dict["equipment"] end
        if haskey(dict, "recording_additional") recording_additional = dict["recording_additional"] end
    catch y
        warn("Error reading startBDFPluswritefile ID file $json_idfile: $y")
    end
    startBDFPluswritefile(signalcount, patientID, recording, patientcode,
                               gender, birthdate, patientname, patient_additional,
                               admincode, technician, equipment, recording_additional)
end


"""
    setplustimenow
Set time of the BDF+ file data being acquired to current time
"""
function setplustimenow(bdfh)
    datetime = now()
    bdfh.startdate_day = Dates.day(datetime)
    bdfh.startdate_month = Dates.month(datetime)
    bdfh.startdate_year = Dates.year(datetime)
    bdfh.starttime_hour = Dates.hour(datetime)
    bdfh.starttime_minute = Dates.minute(datetime)
    bdfh.starttime_second = Dates.second(datetime)
    bdfh.startdatestring = uppercase(Dates.format(datetime, "dd-u-yyyy"))
    return datetime
end


function ganglion4channelsignalparam(bdfh; smp_per_record=250,
                                     labels=["1", "2", "3", "4", "5"],
                                     transtype="active electrode", physdim="uV",
                                     prefilter="None")
    bdfh.signalparam = Array{ChannelParam,1}()
    for i in 1:5
        parm = ChannelParam()
        parm.label = labels[i]
        parm.transducer = transtype
        parm.physdimension = physdim
        parm.physmin = GANGLIONPHYSICALMINIMUM
        parm.physmax = GANGLIONPHYSICALMAXIMUM
        parm.digmin = INT24MINIMUM
        parm.digmax = INT24MAXIMUM
        parm.smp_per_record = smp_per_record
        parm.prefilter= prefilter
        if i == 5
            parm.annotation = true
            parm.transducer=""
            parm.prefilter = ""
        end
        push!(bdfh.signalparam, parm)
    end
    bdfh.annotationchannel = 5
    bdfh
end


"""
    makeganglionrecord
Make a single record from signals at time rectime after start of recording.
Use the fifth (annotation) channel for the BDFPlus timestamp and for any accelerometer data.
Record is of 1.0 sec, so if data rate is 250 Hz, five channels is
3 bytes per datapoint * 250 * 5 = 3750 bytes. The wifi server, commandet driver process
uses a separate task to fill a channel with the data in raw packet form to read here.
We only write one averaged accelerometer reading per packet.
Reclen must be a multiple of 15 and should be a multiple of 30 to get best results.
"""
function makeganglionrecord(rectime, packetchannel, acceldata, reclen)
    if reclen % 15 != 0
        throw("makeganglionrecord record length $reclen is not a multiple of 15")
    end
    siglen = div(reclen, 5)
    chan1 = zeros(UInt8, siglen)
    chan2 = zeros(UInt8, siglen)
    chan3 = zeros(UInt8, siglen)
    chan4 = zeros(UInt8, siglen)
    chan5 = zeros(UInt8, siglen)
    annotpos = 1
    xaccel = yaccel = zaccel = numaccelpackets = 0
    for sigpos in 1:3:siglen-1
        data = take!(packetchannel)
        chan1[sigpos:sigpos+2] = data[3:5]
        chan2[sigpos:sigpos+2] = data[6:8]
        chan3[sigpos:sigpos+2] = data[9:11]
        chan4[sigpos:sigpos+2] = data[12:14]
        if sigpos == 1
            timestamp = EDFPlus.trimrightzeros(string(rectime))
            chan5[1:length(timestamp)+3] = Array{UInt8,1}("$timestamp\x14\x14\x00")
            annotpos += (length(timestamp) + 3)
        end
        # TODO: we can set the ganglion board to send button press data instead of accel data
        # this would be logged as a button press annotation in that record
        # We assume accelerometer data here is the standard non-time-stamped version
        if acceldata && data[33] == 0xC0 && findfirst(data[27:32]) > 0
            xaccel += reinterpret(Int16, data[27:28])
            yaccel += reinterpret(Int16, data[29:30])
            zaccel += reinterpret(Int16, data[31:32])
            numaccelpackets += 1
        end
    end
    if acceldata
        xax = round(32.0 * xaccel / numaccelpackets, 4)
        yax = round(32.0 * yaccel / numaccelpackets, 4)
        zax = round(32.0 * zaccel / numaccelpackets, 4)
        atime = EDFPlus.trimrightzeros(string(rectime + reclen/(SAMPLERATE*15* 2)))
        annot = atime * "\x14$xax $yax $zax (x,y,z) accelerometer data in 1/1000 G units\x14"
        chan5[annotpos:annotpos+length(annot)-1] .= Array{UInt8,1}(annot)
    end
    vcat(chan1,chan2,chan3,chan4,chan5)
end


""" dummy function, will in practice do spike detection etc.  """
nilfunc(bdfh, rec) = info("Record $pcount of $maxpacketsreceived.")


function makeganglionbdfplus(path, ip_board, ip_ours; idfile="",
                             packetinspector=nilfunc, packetlen=3750,
                             packetinterval=1.0, maxpackets=72)
    bdfh = (idfile == "") ? startBDFPluswritefile(4): startBDFPluswritefile(idfile, 4)
    ganglion4channelsignalparam(bdfh)
    bdfh.BDFsignals = zeros(Int32,(maxpackets,packetlen))
    packetchannel = rawganglionboard(ip_board, ip_ours, locallogging=true)
    setplustimenow(bdfh)
    pcount = 0
    packettime = 0.0
    while pcount < maxpackets
        rec = makeganglionrecord(packettime, packetchannel, false, packetlen)
        pcount += 1
        packetinspector(bdfh, pcount, maxpackets)
        bdfh.BDFsignals[pcount,:] .= rec
        packettime += packetinterval
    end
    bdfh.file_duration = Float64(maxpackets)
    bdfh.datarecords = maxpackets
    EDFPlus.writefile!(bdfh, path)
end


if PROGRAM_FILE == "OpenBCI_WiFi.jl"
    makeganglionbdfplus("testfile.bdf", "192.168.1.25", "192.168.1.1",
                         idfile="patientdata.json")
end


end # module
