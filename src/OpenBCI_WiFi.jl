#=
## File = OpenBCI_WiFi.jl
## Author = William Herrera
## Version = 0.016
## Copyright = Copyright William Herrera, 2018
## Creation Date = 16 Jan 2018
## Purpose =  EEG WiFi routines using OpenBCI Arduino hardware
=#

module OpenBCI_WiFi
using Logging
using EDFPlus
using HTTP
using JSON
using Compat
import HTTP: get, post


"""
See [http://docs.openbci.com/Hardware/03-Cyton_Data_Format#cyton-data-format-binary-format]
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


# Commands for board as in SDK http://docs.openbci.com/software/01-Open BCI_SDK
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


""" Send a command to the OpenBCI hardware via the WiFI http server POST /command JSON interface """
function postwrite(server, command, saywarn=true)
    resp = post("$server/command", 
                "Content-Type"=>"application/json", 
                JSON.json(Dict("command"=>command)))
    if resp.status == 200
        info("command was $command, response was $(resp.body))")
    elseif saywarn
        warn("Got status $(resp.status), failed to get proper response from $server after command $command")
    end
end


""" The functions below all are specific calls to the postwrite function above """
stop(server) = postwrite(server,command_stop)           # stop streaming "s"
softreset(server) = postwrite(server, "v")              # reset peripherals only
start(server) = postwrite(server, command_startBinary)  # 'b', binary streaming should now start
getfs(server) = postwrite(server, "~~")                 # reply is sample rate
setnonstandardfs(server, srate=200) = postwrite(server, sratecommands[srate])
getregisters(server) = postwrite(server, "?")
enablechannels(server, chan=[1,2,3,4]) = for i in chan postwrite(server, b"qwer"[i]) end
disablechannel(server, chan) = postwrite(server,chan)
startsquarewave(server) = postwrite(server, "[")
stopsquarewave(server) = postwrite(server, "]", false)
startimpedancetest(server) = postwrite(server, "z")
stopimpedancetest(server) = postwrite(server, "Z", false)
startaccelerometer(server) = postwrite(server, "n")
stopaccelerometer(server) = postwrite(server, "N", false)
startSDlogging(server) = postwrite(server, "a")         # up to 14 seconds of SD card logging
stopSDlogging(server) = postwrite(server, "j", false)   # stop logging
attachshield(server) = postwrite(server, "{")
detachshield(server) = postwrite(server, "}")
resetshield(server) = postwrite(server,";")


"""
    asyncsocketserver(serveraddress, portnum, packetchannel)
Server task, run in separate task, gets stream of packets from the OpenBCI Wifi hardware
and sends back to main process via a channel
serveraddress: in form of "http://111.222.133/" (used to restart if error)
portnum: our port number the OpenBCI Wifi will connect to
packetchannel: the channel over which we send data to the parent task
"""
function asyncsocketserver(serveraddress, portnum, packetchannel)
    numberofgets = 1
    wifisocket = TCPSocket()
    try
        info("Entered server async code")
        while true
            server = listen(IPv4(0), portnum)
            wifisocket = accept(server)
            info("socket service connected to ganglion board")
            bytes = b""
            top = 1
            while isopen(wifisocket)
                bytes = vcat(bytes,read(wifisocket,33))
                if length(bytes) >= 33
                    if bytes[1] == 0xA0 # in sync?
                        put!(packetchannel, bytes[1:33])
                        bytes = bytes[34:end]
                    elseif coalesce((top = findfirst(x->x==0xA0, bytes)), 0) > 0
                        info("sync: dropping bytes above position $top")
                        bytes = bytes[top:end]
                    else
                        info("sync: dumping buffer")
                        bytes = b""
                    end
                else
                    yield()
                    sleep(0.01)
                end
            end
            # if we got here we may need to do a restart, but try a new get also
            numberofgets += 1
            info("Redoing get for binary stream, will now have done get $numberofgets times")
            get("$serveraddress/stream/start")
        end
    catch y
        info("Caught exception $y")
        # either error or the channel to process the packets has been closed
        info("Exiting WiFi streaming task")
        close(wifisocket)
    end
end


"""
    rawOpenBCIboard
Set up the raw OpenBCI WiFI shield connection with the OpenBCI ganglion board.
Args:
ip_board         the ip number of the WiFi shield
ip_ours          the ip to get the board's stream, usually this computer
--- optional named arguments ---
portnum          the port number to which the shield will stream data
fs               sampling rate, usually 250 == SAMPLERATE
latency          latency in microseconds, time between packets, default 15 msec
locallogging     true if loglevel is to be info rather than warn
logSD            true if should log to SD card
useaccelerometer true if accelerometer data to be sent
impedancetest    true if impedance check to be done
maketestwave     true if test square-wave signal to be generated
"""
function rawOpenBCIboard(ip_board, ip_ours; portnum=DEFAULT_STREAM_PORT,
                         fs=250, latency=15000, locallogging=false,
                         logSD=false, useaccelerometer=true,
                         impedancetest=false, maketestwave=false)
    if locallogging
        Logging.configure(level=INFO)
        info("--- Logging starting session ---")
    else
        Logging.configure(level=WARNING)
    end
    serveraddress = "http://$ip_board"
    resp = get("$serveraddress/board")
    if resp.status == 200
        # expect: {"board_connected": true, "board_type": "string",
        # "gains": [ null ], "num_channels": 0}
        sysinfo = JSON.parse(convert(String,resp.body))
        info("board reports $sysinfo")
        num_signals = sysinfo["num_channels"]
        if !(num_signals in (4, 8, 16))
            warn("board reports $num_signals channels")
        end
    end
    # It's important to start the server process before we set up the TCP port
    # so that the board will find the socket for the connection right away.
    packetchannel = Channel(2400)
    @async(asyncsocketserver(serveraddress, portnum, packetchannel))
    # Now we set up the TCP port connection from the board to our service
    jso = Dict("ip"=>ip_ours, "port"=>portnum, "output"=>"raw", "latency"=>latency)
    resp = post("$serveraddress/tcp", "Content-Type"=>"application/json", JSON.json(jso))
    info("sending json")
    if resp.status == 200
        tcpinfo = JSON.parse(convert(String,resp.body))
        if haskey(tcpinfo, "connected") && tcpinfo["connected"]
            info("Wifi shield TCP server, command connection established, info is $tcpinfo")
        else
            throw("TCP connection failure with $serveraddress")
        end
    else
        warn("tcp config error status code: $(resp.status)")
    end
    if fs != 250 && fs in [1600, 800, 400, 200]
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
    if maketestwave
        startsquarewave(serveraddress)
    else
        stopsquarewave(serveraddress)
    end
    # now do data collection as a task that will terminate only when we tell it later
    # stop via exception when the channel is closed
    info("asking for stream")
    get("$serveraddress/stream/start")
    sleep(1)
    if impedancetest
        info("Impedance check will be done for one second.")
        startimpedancetest(serveraddress)
        sleep(1)
        stopimpedancetest(serveraddress)
    end
    # return the channel where the data packets will be stacked and the number of channels
    packetchannel, num_signals
end

""" Create the header and file descriptions of the future BDF+ file """
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
    startBDFPluswritefile(json_idfile, signalcount)
json_idfile is a file containing JSON formatted patient information.
"""
function startBDFPluswritefile(json_idfile::String, signalcount::Int)
    # if the json file fails as a data source, we use anonymous defaults
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


""" function to help set up BDF+ file header """
function makechannelsignalparam(bdfh, records, size, interval, num_signals;
                                     fs=250, labels=[string(locali) for locali in 1:num_signals+1],
                                     transtype="active electrode", physdim="uV",
                                     prefilter="None")
    bdfh.signalparam = Array{ChannelParam,1}()
    for i in 1:num_signals+1
        parm = ChannelParam()
        parm.label = labels[i]
        parm.transducer = transtype
        parm.physdimension = physdim
        if num_signals < 5
            parm.physmin = GANGLIONPHYSICALMINIMUM
            parm.physmax = GANGLIONPHYSICALMAXIMUM
        else
            parm.physmin = CYTONPHYSICALMINIMUM
            parm.physmax = CYTONPHYSICALMAXIMUM
        end
        parm.digmin = INT24MINIMUM
        parm.digmax = INT24MAXIMUM
        parm.smp_per_record = fs
        parm.bufoffset = (i-1) * 3 * fs + 1
        parm.prefilter= prefilter
        if i == num_signals+1
            parm.annotation = true
            parm.transducer=""
            parm.prefilter = ""
        end
        push!(bdfh.signalparam, parm)
    end
    bdfh.datarecords = records
    bdfh.datarecord_duration = interval
    bdfh.recordsize = size
    bdfh.annotationchannel = num_signals+1
    bdfh.file_duration = Float64(records*interval)
    bdfh.headersize = 256 * (num_signals+2)
end


"""
    makeBDFplusrecord
Make a single record from signals at time rectime after start of recording.
Use the last (annotation) channel for the timestamp and accelerometer
annotation data. The record size defaults to be 1 second in duration.
So, if data rate is 250 Hz, for ganglion board's 4 data channels, five
channels total and 3 bytes per datapoint, equals 3 * 250 * 5 = 3750 bytes,
9 cyton channnels is 6750 bytes, and the 17 for the cyton with daisyboard
are then 12750 bytes. The wifi server sends packet data via a driver task,
which fills a Channel (packetchannel) with the data in raw packet form to
read by the main thread. We write one averaged accelerometer reading per
packet. Reclen must be a multiple of 3 * (number of signals + 1).
Returns: one record of length reclen bytes.
--- Arguments ---
-rectime time in seconds since start of recording
-packetchannel the Channel that the server task uses to send data
-acceldata true if acceleromenter data is to be used
-reclen record size, see above for best defaults
-num_channels total number of channels in the record including annotation channel
-daisy true if cyton has a daisyboard (take two packets per 16 channels if true)
"""
function makeBDFplusrecord(rectime, packetchannel, acceldata, reclen, num_channels, daisy=false)
    if reclen % (3*num_channels) != 0
        throw("makeganglionrecord record length $reclen is not a multiple of 3*num_channels")
    end
    siglen = div(reclen, num_channels)
    chan = zeros(UInt8, (num_channels, siglen))
    annotpos = 1
    xaccel = yaccel = zaccel = numaccelpackets = 0
    for sigpos in 1:3:siglen-1
        data = take!(packetchannel)
        if daisy # Cyton board using 16 channel daisy
            if data[2] & 1 == 0  # even packet number, maybe 0
                data = take!(packetchannel) # get an odd numbered packet
            end
            data2 = take!(packetchannel) # second packet for daisy
        end
        # the bigendians and the littleendians are clashing again...
        # OpenBSD boards send bigendian, BDF and EDF files are littleendian
        for i in 1:num_channels-1
            if daisy && i > 8
                j = i - 8  # daisy packet channels 9 through 16
                chan[i, sigpos:sigpos+2] .= reverse(data2[j*3:j*3+2])
            else # all but daisy channels
                chan[i, sigpos:sigpos+2] .= reverse(data[i*3:i*3+2])
            end
        end
        if sigpos == 1
            timestamp = EDFPlus.trimrightzeros(string(rectime))
            chan[num_channels, 1:length(timestamp)+4] = Array{UInt8,1}("+$timestamp\x14\x14\x00")
            annotpos += (length(timestamp) + 4)
        end
        # TODO: we can set the ganglion board to send button press data instead of accel data
        # this would be logged as a button press annotation in that record
        # We assume accelerometer data here is the standard non-time-stamped version
        if acceldata && data[33] == 0xC0 && coalesce(findfirst(data[27:32]), 0) > 0
            xaccel += data[27] >> 8 + data[28]
            yaccel += data[29] >> 8 + data[30]
            zaccel += data[31] >> 8 + data[32]
            numaccelpackets += 1
        end
    end
    if acceldata
        xax = round(32.0 * xaccel / numaccelpackets, 4)
        yax = round(32.0 * yaccel / numaccelpackets, 4)
        zax = round(32.0 * zaccel / numaccelpackets, 4)
        atime = EDFPlus.trimrightzeros(string(rectime + reclen/(SAMPLERATE*15* 2)))
        annot = "+" * atime * "\x14$xax $yax $zax (x,y,z) accelerometer data in 1/1000 G units\x14\x00"
        chan[num_channels, annotpos:annotpos+length(annot)-1] .= Array{UInt8,1}(annot)
    end
    recbytes = b""
    for i in 1:num_channels
        recbytes = vcat(recbytes, chan[i,:])
    end
    rec = Array{Int32,1}(div(reclen,3))
    for i in 1:3:reclen-1
        rec[div(i,3)+1] = Int(reinterpret(EDFPlus.Int24, recbytes[i:i+2])[1])
    end
    rec
end


""" dummy function, will in practice do fft, spike detection etc.  """
nilfunc(bdfh, pcount, maxrecords) = info("Record $pcount of $maxrecords received.")


"""
    makeganglionbdfplus
Set up and sample streaming ganglion board and write a BDF+ file as output.
Args:
path             pathname of BDF+ file to be written at end of recording run
ip_board         the ip number of the WiFi shield
ip_ours          the ip number of the machine getting the stream, generally this computer
records          number of records to write, is same as seconds in file with defaults
   ----- optional arguments below -----
idfile           optional JSON file for patient and machine data
inspector        logging or detection function, called once every BDF+ record
portnum          the port number to which the shield will stream data
recordsize       size of each record to write in bytes
fs               sampling rate, usually 250 == SAMPLERATE
latency          latency in microseconds, time between packets, default 15 msec
locallogging     true if loglevel is to be info rather than warn
logSD            true if should log to SD card for 14 sec
accelannotations true if accelerometer data to be recorded
impedancetest    true if impedance check to be done
maketestwave     true if squarewave test signal to be generated
"""
function makeganglionbdfplus(path, ip_board, ip_ours, records=60; idfile="",
                             inspector=nilfunc, portnum=DEFAULT_STREAM_PORT,
                             recordsize=3750, fs=SAMPLERATE, latency=15000,
                             locallogging=true, logSD=false, accelannotations=false,
                             impedancetest=false, maketestwave=false)
    bdfh = (idfile == "") ? startBDFPluswritefile(4) : startBDFPluswritefile(idfile, 4)
    packetinterval = recordsize / 3750.0
    makechannelsignalparam(bdfh, records, recordsize, packetinterval, 4)
    bdfh.BDFsignals = zeros(Int32,(records,div(recordsize,3)))
    packetchannel, numsig = rawOpenBCIboard(ip_board, ip_ours, portnum=portnum, fs=fs,
                                     latency=latency, locallogging=locallogging,
                                     logSD=logSD, useaccelerometer=accelannotations,
                                     impedancetest=impedancetest, maketestwave=maketestwave)
    setplustimenow(bdfh)
    pcount = 0
    packettime = 0.0
    while pcount < records
        rec = makeBDFplusrecord(packettime, packetchannel, accelannotations, recordsize, 5)
        pcount += 1
        inspector(bdfh, pcount, records)
        bdfh.BDFsignals[pcount,:] = rec
        packettime += packetinterval
    end
    EDFPlus.writefile!(bdfh, path)
end

"""
    makecyton8bdfplus
Set up and sample streaming cyton 8-channel board and write a BDF+ file as output.
Args:
path             pathname of BDF+ file to be written at end of recording run
ip_board         the ip number of the WiFi shield
ip_ours          the ip number of the machine getting the stream, generally this computer
records          number of records to write, is same as seconds in file with defaults
   ----- optional arguments below -----
idfile           optional JSON file for patient and machine data
inspector        logging or detection function, called once every BDF+ record
portnum          the port number to which the shield will stream data
recordsize       size of each record to write in bytes
fs               sampling rate, usually 250 == SAMPLERATE
latency          latency in microseconds, time between packets, default 15 msec
locallogging     true if loglevel is to be info rather than warn
logSD            true if should log to SD card for 14 sec
accelannotations true if accelerometer data to be recorded
impedancetest    true if impedance check to be done
maketestwave     true if squarewave test signal to be generated
"""
function makecyton8bdfplus(path, ip_board, ip_ours, records=60; idfile="",
                             inspector=nilfunc, portnum=DEFAULT_STREAM_PORT,
                             recordsize=6750, fs=SAMPLERATE, latency=15000,
                             locallogging=true, logSD=false, accelannotations=false,
                             impedancetest=false, maketestwave=false)
    bdfh = (idfile == "") ? startBDFPluswritefile(8): startBDFPluswritefile(idfile, 8)
    packetinterval = recordsize / 6750.0
    makechannelsignalparam(bdfh, records, recordsize, packetinterval, 8)
    bdfh.BDFsignals = zeros(Int32,(records,div(recordsize,3)))
    packetchannel, numsig = rawOpenBCIboard(ip_board, ip_ours, portnum=portnum, fs=fs,
                                     latency=latency, locallogging=locallogging,
                                     logSD=logSD, useaccelerometer=accelannotations,
                                     impedancetest=impedancetest, maketestwave=maketestwave)
    setplustimenow(bdfh)
    pcount = 0
    packettime = 0.0
    while pcount < records
        rec = makeBDFplusrecord(packettime, packetchannel, accelannotations, recordsize, 9)
        pcount += 1
        inspector(bdfh, pcount, records)
        bdfh.BDFsignals[pcount,:] = rec
        packettime += packetinterval
    end
    EDFPlus.writefile!(bdfh, path)
end


"""
    makecyton16bdfplus
Set up cyton 16-channel board with daisy baord for 16 signal channels and write a BDF+ file as output.
Args:
path             pathname of BDF+ file to be written at end of recording run
ip_board         the ip number of the WiFi shield
ip_ours          the ip number of the machine getting the stream, generally this computer
records          number of records to write, is same as seconds in file with defaults
   ----- optional arguments below -----
idfile           optional JSON file for patient and machine data
inspector        logging or detection function, called once every BDF+ record
portnum          the port number to which the shield will stream data
recordsize       size of each record to write in bytes
fs               sampling rate, usually 250 == SAMPLERATE
latency          latency in microseconds, time between packets, default 15 msec
locallogging     true if loglevel is to be info rather than warn
logSD            true if should log to SD card for 14 sec
accelannotations true if accelerometer data to be recorded
impedancetest    true if impedance check to be done
maketestwave     true if squarewave test signal to be generated
"""
function makecyton16bdfplus(path, ip_board, ip_ours, records=60; idfile="",
                             inspector=nilfunc, portnum=DEFAULT_STREAM_PORT,
                             recordsize=12750, fs=SAMPLERATE, latency=15000,
                             locallogging=true, logSD=false, accelannotations=false,
                             impedancetest=false, maketestwave=false)
    bdfh = (idfile == "") ? startBDFPluswritefile(16): startBDFPluswritefile(idfile, 16)
    packetinterval = recordsize / 12750.0
    makechannelsignalparam(bdfh, records, recordsize, packetinterval, 16)
    bdfh.BDFsignals = zeros(Int32,(records,div(recordsize,3)))
    packetchannel, numsig = rawOpenBCIboard(ip_board, ip_ours, portnum=portnum, fs=fs,
                                     latency=latency, locallogging=locallogging,
                                     logSD=logSD, useaccelerometer=accelannotations,
                                     impedancetest=impedancetest, maketestwave=maketestwave)
    setplustimenow(bdfh)
    pcount = 0
    packettime = 0.0
    while pcount < records
        rec = makeBDFplusrecord(packettime, packetchannel, accelannotations, recordsize, 17)
        pcount += 1
        inspector(bdfh, pcount, records)
        bdfh.BDFsignals[pcount,:] = rec
        packettime += packetinterval
    end
    EDFPlus.writefile!(bdfh, path)
end


end # module
