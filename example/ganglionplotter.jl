using OpenBCI, EDFPlus, GLMakie

boardIP = "192.168.1.23" # set to your configuration, letting board port be the default
myIP = "192.168.1.1"
idfile = "../test/patientdata.json"

const SAMPLE_RATE = 250            # sample rate in Hz
const WINDOW_SECONDS = 10          # seconds time width of visible scrolling window
const MIN_YRANGE = 50.0            # minimum +/- y range (same units as EEG)

# ---- Build the figure ONCE at startup ----
struct DataObservable
    pts1::Observable{Vector{Point2f}}
    pts2::Observable{Vector{Point2f}}
    title::Observable{String}
end

const EEG_DATA = DataObservable(Observable(Point2f[]), Observable(Point2f[]), Observable("Waiting for data..."))

function setupwindow()
    fig = Figure(size=(1000, 600))
    ax1 = Axis(fig[1, 1];
                 title=EEG_DATA.title,
                 yticksvisible=false, yticklabelsvisible=false,
                 ylabel="Fp1-T3")
    ax2 = Axis(fig[2, 1];
                 xlabel="Time (s)",
                 yticksvisible=false, yticklabelsvisible=false,
                 ylabel="Fp2-T4")
    hidexdecorations!(ax1, grid=false)
    linkxaxes!(ax1, ax2)

    lines!(ax1, EEG_DATA.pts1)
    lines!(ax2, EEG_DATA.pts2)
    xlims!(ax1, 0, WINDOW_SECONDS)
    ylims!(ax1, -MIN_YRANGE, MIN_YRANGE)
    ylims!(ax2, -MIN_YRANGE, MIN_YRANGE)

    screen = display(fig) # window opened once and left open during EEG recording
    return screen
end

const SCREEN = setupwindow()

# Packets are rows, samples are columns, so transpose packets.
# so that time runs forward through the vector.
channel(sig, rows, cols) = vec(permutedims(sig[rows, cols]))
symrange(y) = (m = max(MIN_YRANGE, 1.1 * maximum(abs, y)); (-m, m))

"""
Update the real-time scrolling plot with the latest bipolar OpenBCI EEG data.
"""
function plottwobipolars(bdfh, pcount, maxpackets)
    pcount < 2 && return # first packet is for setup time

    # Packets made available so far is pcount, lastpacket is one right now
    lastpacket  = pcount - 1
    firstpacket = max(1, pcount - WINDOW_SECONDS)
    rows  = firstpacket:lastpacket

    c1 = channel(bdfh.BDFsignals, rows, 1:250)
    c2 = channel(bdfh.BDFsignals, rows, 251:500)
    c3 = channel(bdfh.BDFsignals, rows, 501:750)
    c4 = channel(bdfh.BDFsignals, rows, 751:1000)

    Fp1T3 = c2 .- c1
    Fp2T4 = c4 .- c3
    Fp1T3 = EDFPlus.lowpassfilter(Fp1T3, SAMPLE_RATE, 40.0)
    Fp2T4 = EDFPlus.lowpassfilter(Fp2T4, SAMPLE_RATE, 40.0)
    Fp1T3 = EDFPlus.highpassfilter(Fp1T3, SAMPLE_RATE, 0.5)
    Fp2T4 = EDFPlus.highpassfilter(Fp2T4, SAMPLE_RATE, 0.5)

    # t is the absolute time in seconds for each sample in the window
    t0 = (firstpacket - 1) # seconds at start of window
    t  = t0 .+ (0:length(Fp1T3)-1) ./ SAMPLE_RATE

    # Update data via Observable
    EEG_DATA.pts1[] = Point2f.(t, Fp1T3)
    EEG_DATA.pts2[] = Point2f.(t, Fp2T4)
    EEG_DATA.title[] = "Elapsed: $(lastpacket) s   (showing lastpacket $WINDOW_SECONDS s)"

    # Scroll screen
    tend = lastpacket
    xlims!(SCREEN[1], max(0, tend - WINDOW_SECONDS), max(WINDOW_SECONDS, tend))
    ylims!(SCREEN[1], symrange(Fp1T3)...)
    ylims!(SCREEN[2], symrange(Fp2T4)...)
    return
end

# Start the EEG recording, writing to `examplefile.bdf` as well as displaying data
makeganglionbdfplus("examplefile.bdf", boardIP, myIP, 120,
                    idfile=idfile, inspector=plottwobipolars)

# Keep the window open after acquisition ends and close the window to exit
wait(SCREEN)
