"""
These tests exercise the non-device-related logic of the package (BDF+ header
construction, channel parameter setup, packet decoding/assembly, accelerometer
byte combination, and HTTP error-handling helpers) without requiring an actual
OpenBCI board or network connection, so they run reliably in GitHub's CI.

To test actual port connected hardware is mostly outside of a Github CI type test harness.
To actually use the OpenBCI board in this testing, set the OPENBCI_RUN_HARDWARE_TESTS 
environment variable to "true" add the variables OPENBCI_BOARD_IP = "the ip" and 
OPENBCI_BOARD_PORT = "the port" so the board is reachable at the configured IP addresses.
"""

using Test, OpenBCI, Dates, Logging

# This may be a CI run, so try to silence warnings about no hardware connected
global_logger(ConsoleLogger(stderr, Logging.Error))

# Patient type data in JSON format file in this directory for testing purposes
const PATIENT_JSON = joinpath(@__DIR__, "patientdata.json")

@testset "OpenBCI.jl" begin

    @testset "board/command constants" begin
        @test length(OpenBCI.command_activate_channel) == 8
        @test OpenBCI.command_activate_channel[1:4] == ["q", "w", "e", "r"]
        @test length(OpenBCI.command_deactivate_channel) == 8
        @test OpenBCI.sratecommands[200] == '7'
        @test OpenBCI.sratecommands[25600] == '0'
        @test OpenBCI.PACKET_SIZE == 33
        @test OpenBCI.START_BYTE == 0xA0
        @test OpenBCI.END_BYTE == 0xC0

        @test OpenBCI.GANGLION_NUM_SIGNALS == 4
        @test OpenBCI.GANGLION_RECORD_CHANNELS == 5
        @test OpenBCI.GANGLION_RECORD_SIZE == 3750
        @test OpenBCI.CYTON8_NUM_SIGNALS == 8
        @test OpenBCI.CYTON8_RECORD_CHANNELS == 9
        @test OpenBCI.CYTON8_RECORD_SIZE == 6750
        @test OpenBCI.CYTON16_NUM_SIGNALS == 16
        @test OpenBCI.CYTON16_RECORD_CHANNELS == 17
        @test OpenBCI.CYTON16_RECORD_SIZE == 12750

        # record size must equal 3 bytes/sample * SAMPLERATE * record channel count
        @test OpenBCI.GANGLION_RECORD_SIZE ==
            3 * Int(OpenBCI.SAMPLE_RATE) * OpenBCI.GANGLION_RECORD_CHANNELS
        @test OpenBCI.CYTON8_RECORD_SIZE ==
            3 * Int(OpenBCI.SAMPLE_RATE) * OpenBCI.CYTON8_RECORD_CHANNELS
        @test OpenBCI.CYTON16_RECORD_SIZE ==
            3 * Int(OpenBCI.SAMPLE_RATE) * OpenBCI.CYTON16_RECORD_CHANNELS
    end

    @testset "combineaccelbytes" begin
        combine = OpenBCI.combineaccelbytes
        @test combine(0x00, 0x00) == 0
        @test combine(0x00, 0x01) == 1
        @test combine(0x00, 0xff) == 255
        @test combine(0x01, 0x00) == 256
        @test combine(0x7f, 0xff) == 32767  # max positive Int16
        @test combine(0x80, 0x00) == -32768 # min (most negative) Int16
        @test combine(0xff, 0xff) == -1     # -1 in two's complement
    end

    @testset "loggedrequest" begin
        # a successful request's result is passed straight through
        result = OpenBCI.loggedrequest(
            (url, args...; kwargs...) -> (url, args),
            "http://example.test",
            "x",
        )
        @test result == ("http://example.test", ("x",))

        # a failing request logs and rethrows the original exception unchanged
        @test_throws ErrorException OpenBCI.loggedrequest(
            (url) -> error("simulated failure"),
            "http://example.test",
        )
    end

    @testset "startBDFPluswritefile (explicit args)" begin
        bdfh = OpenBCI.startBDFPluswritefile(
            4,
            "patient1",
            "rec1",
            "code1",
            "M",
            "01-JAN-2000",
            "name1",
            "add1",
            "admin1",
            "tech1",
            "equip1",
            "recadd1",
        )
        @test bdfh.writemode
        @test bdfh.bdfplus
        @test !bdfh.edf
        @test !bdfh.bdf
        @test bdfh.channelcount == 5 # 4 signals + 1 annotation channel
        @test bdfh.annotationchannel == 5
        @test bdfh.patient == "patient1"
        @test bdfh.recording == "rec1"
        @test bdfh.patientcode == "code1"
        @test bdfh.gender == "M"
        @test bdfh.patientname == "name1"
        @test bdfh.technician == "tech1"
        @test bdfh.equipment == "equip1"
    end

    @testset "startBDFPluswritefile (JSON idfile)" begin
        bdfh = OpenBCI.startBDFPluswritefile(PATIENT_JSON, 4)
        @test bdfh.patientcode == "7777777"
        @test bdfh.gender == "M"
        @test bdfh.birthdate == "01-JAN-2000" # uppercased by the loader
        @test bdfh.patientname == "EEG_Subject"
        @test bdfh.technician == "EEG_TECH"
        @test bdfh.equipment == "OpenBCI_Ganglion"
        @test bdfh.channelcount == 5

        # a missing/invalid id file should fall back to anonymous defaults instead of throwing
        bdfh2 = OpenBCI.startBDFPluswritefile("does_not_exist.json", 8)
        @test bdfh2.channelcount == 9
        @test bdfh2.patient == ""
        @test bdfh2.patientcode == ""
    end

    @testset "setplustimenow" begin
        bdfh = OpenBCI.startBDFPluswritefile(4)
        before = now()
        returned = OpenBCI.setplustimenow(bdfh)
        after = now()
        @test before <= returned <= after
        @test bdfh.startdate_year == Dates.year(returned)
        @test bdfh.startdate_month == Dates.month(returned)
        @test bdfh.startdate_day == Dates.day(returned)
        @test bdfh.starttime_hour == Dates.hour(returned)
    end

    @testset "makechannelsignalparam" begin
        bdfh = OpenBCI.startBDFPluswritefile(4)
        OpenBCI.makechannelsignalparam(bdfh, 60, OpenBCI.GANGLION_RECORD_SIZE, 1.0, 4)
        @test length(bdfh.signalparam) == 5
        @test bdfh.signalparam[1].physmin == OpenBCI.GANGLION_PHYSICAL_MINIMUM
        @test bdfh.signalparam[1].physmax == OpenBCI.GANGLION_PHYSICAL_MAXIMUM
        @test bdfh.signalparam[1].digmin == OpenBCI.INT_24_MINIMUM
        @test bdfh.signalparam[1].digmax == OpenBCI.INT_24_MAXIMUM
        @test bdfh.signalparam[1].annotation == false
        @test bdfh.signalparam[5].annotation == true
        @test bdfh.signalparam[2].bufoffset == (2 - 1) * 3 * 250 + 1
        @test bdfh.datarecords == 60
        @test bdfh.annotationchannel == 5

        bdfh8 = OpenBCI.startBDFPluswritefile(8)
        OpenBCI.makechannelsignalparam(bdfh8, 60, OpenBCI.CYTON8_RECORD_SIZE, 1.0, 8)
        @test length(bdfh8.signalparam) == 9
        @test bdfh8.signalparam[1].physmin == OpenBCI.CYTON_PHYSICAL_MINIMUM
        @test bdfh8.signalparam[1].physmax == OpenBCI.CYTON_PHYSICAL_MAXIMUM
        @test bdfh8.signalparam[9].annotation == true
    end

    @testset "makeBDFplusrecord: basic ganglion (no daisy, no accel)" begin
        reclen = OpenBCI.GANGLION_RECORD_SIZE
        num_channels = OpenBCI.GANGLION_RECORD_CHANNELS
        siglen = div(reclen, num_channels)
        nsamples = div(siglen, 3)
        packetchannel = Channel{Vector{UInt8}}(nsamples + 10)
        producer = @async begin
            for k in 1:nsamples
                pkt = zeros(UInt8, OpenBCI.PACKET_SIZE)
                pkt[1] = OpenBCI.START_BYTE
                pkt[2] = UInt8(k % 256)
                pkt[OpenBCI.PACKET_SIZE] = OpenBCI.END_BYTE
                # mark only the last byte of each channel's 3-byte group so that,
                # after the board's big-endian bytes are reversed to little-endian,
                # it becomes the least-significant (and only nonzero) byte
                for ch in 1:4
                    pkt[ch * 3 + 2] = UInt8(10 + ch)
                end
                put!(packetchannel, pkt)
            end
        end
        rec = OpenBCI.makeBDFplusrecord(
            0.0,
            packetchannel,
            false,
            reclen,
            num_channels,
            false,
        )
        wait(producer)
        @test length(rec) == div(reclen, 3)
        for ch in 1:4
            chanvals = rec[(ch - 1) * nsamples + 1:ch * nsamples]
            @test all(==(10 + ch), chanvals)
        end
    end

    @testset "makeBDFplusrecord: invalid record length throws" begin
        packetchannel = Channel{Vector{UInt8}}(1)
        @test_throws ErrorException OpenBCI.makeBDFplusrecord(
            0.0,
            packetchannel,
            false,
            100,
            7,
            false,
        )
    end

    @testset "makeBDFplusrecord: daisy (cyton16) combines two packets per sample" begin
        reclen = OpenBCI.CYTON16_RECORD_SIZE
        num_channels = OpenBCI.CYTON16_RECORD_CHANNELS
        siglen = div(reclen, num_channels)
        nsamples = div(siglen, 3)
        packetchannel = Channel{Vector{UInt8}}(2 * nsamples + 10)
        producer = @async begin
            for k in 1:nsamples
                # always emit the odd-numbered packet of the pair first so the
                # consumer's even/odd resync logic never needs to discard one
                oddpkt = zeros(UInt8, OpenBCI.PACKET_SIZE)
                oddpkt[1] = OpenBCI.START_BYTE
                oddpkt[2] = 0x01
                for ch in 1:8
                    oddpkt[ch * 3 + 2] = UInt8(ch) # channels 1..8 marker
                end
                put!(packetchannel, oddpkt)

                evenpkt = zeros(UInt8, OpenBCI.PACKET_SIZE)
                evenpkt[1] = OpenBCI.START_BYTE
                evenpkt[2] = 0x02
                for ch in 1:8
                    evenpkt[ch * 3 + 2] = UInt8(100 + ch) # channels 9..16 marker
                end
                put!(packetchannel, evenpkt)
            end
        end
        rec = OpenBCI.makeBDFplusrecord(
            0.0,
            packetchannel,
            false,
            reclen,
            num_channels,
            true,
        )
        wait(producer)
        @test length(rec) == div(reclen, 3)
        for ch in 1:8
            chanvals = rec[(ch - 1) * nsamples + 1:ch * nsamples]
            @test all(==(ch), chanvals)
        end
        for ch in 9:16
            chanvals = rec[(ch - 1) * nsamples + 1:ch * nsamples]
            @test all(==(92 + ch), chanvals) # 100 + (ch - 8)
        end
    end

    @testset "makeBDFplusrecord: accelerometer annotation round trip" begin
        reclen = OpenBCI.GANGLION_RECORD_SIZE
        num_channels = OpenBCI.GANGLION_RECORD_CHANNELS
        siglen = div(reclen, num_channels)
        nsamples = div(siglen, 3)
        packetchannel = Channel{Vector{UInt8}}(nsamples + 10)
        producer = @async begin
            for k in 1:nsamples
                pkt = zeros(UInt8, OpenBCI.PACKET_SIZE)
                pkt[1] = OpenBCI.START_BYTE
                pkt[2] = UInt8(k % 256)
                pkt[OpenBCI.PACKET_SIZE] = OpenBCI.END_BYTE
                # x=1, y=2, z=3 accelerometer counts (big-endian hi,lo byte pairs)
                pkt[27] = 0x00
                pkt[28] = 0x01
                pkt[29] = 0x00
                pkt[30] = 0x02
                pkt[31] = 0x00
                pkt[32] = 0x03
                put!(packetchannel, pkt)
            end
        end
        rec = OpenBCI.makeBDFplusrecord(
            0.0,
            packetchannel,
            true,
            reclen,
            num_channels,
            false,
        )
        wait(producer)
        @test length(rec) == div(reclen, 3)

        # reconstruct the annotation channel's raw bytes from the decoded Int32
        # samples and verify the accelerometer annotation text was embedded
        annotstart = (num_channels - 1) * nsamples + 1
        annotsamples = rec[annotstart:annotstart + nsamples - 1]
        bytes = UInt8[]
        for v in annotsamples
            push!(bytes, UInt8(v & 0xff))
            push!(bytes, UInt8((v >> 8) & 0xff))
            push!(bytes, UInt8((v >> 16) & 0xff))
        end
        text = String(bytes)
        @test occursin("accelerometer data", text)
        # average of 1,2,3 counts scaled by 32.0 => 32.0, 64.0, 96.0
        @test occursin("32.0 64.0 96.0", text)
    end

    @testset "nilfunc default inspector" begin
        bdfh = OpenBCI.startBDFPluswritefile(4)
        @test OpenBCI.nilfunc(bdfh, 1, 10) === nothing
    end

    @testset "public API shape" begin
        @test :makeganglionbdfplus in names(OpenBCI)
        @test :makecyton8bdfplus in names(OpenBCI)
        @test :makecyton16bdfplus in names(OpenBCI)
        @test hasmethod(OpenBCI.makeganglionbdfplus, (String, String, String))
        @test hasmethod(OpenBCI.makecyton8bdfplus, (String, String, String))
        @test hasmethod(OpenBCI.makecyton16bdfplus, (String, String, String))
    end

    @testset "Hardware integration (requires realtime OpenBCI hardware)" begin
        # These exercise the actual WiFi/TCP path against real OpenBCI hardware
        # and are skipped by default since no board is available in CI. To run
        # them, set OPENBCI_RUN_HARDWARE_TESTS=true and point
        # OPENBCI_BOARD_IP/OPENBCI_HOST_IP at a reachable board and host.
        if get(ENV, "OPENBCI_RUN_HARDWARE_TESTS", "false") == "true"
            boardIP = get(ENV, "OPENBCI_BOARD_IP", "192.168.1.2")
            hostIP = get(ENV, "OPENBCI_HOST_IP", "192.168.1.1")
            outfile = tempname() * ".bdf"
            try
                OpenBCI.makeganglionbdfplus(
                    outfile,
                    boardIP,
                    hostIP,
                    2,
                    idfile = PATIENT_JSON,
                )
                @test isfile(outfile)
            finally
                isfile(outfile) && rm(outfile)
            end
        else
            @test_skip "set OPENBCI_RUN_HARDWARE_TESTS=true with a reachable board to run this test"
        end
    end

end
