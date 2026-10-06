"""
This script connects to an OpenBCI board, processes EEG data, and plots
   two bipolar channels (Fp1-T3 and Fp2-T4) from a Ganglion OpenBCI device in real-time.
"""

using OpenBCI, EDFPlus, CairoMakie

boardIP = "192.168.1.23"
myIP = "192.168.1.1"
idfile = "../test/patientdata.json"

const PLOT_INTERVAL = 10

linspace(start, stop, len) = LinRange{Float64}(start, stop, len)

function plottwobipolars(bdfh, pcount, maxpackets)
    m, n = pcount - PLOT_INTERVAL, pcount - 1
    if pcount > PLOT_INTERVAL && pcount % PLOT_INTERVAL == 1
        c1data = bdfh.BDFsignals[m:n, 1:250][:]
        c2data = bdfh.BDFsignals[m:n, 251:500][:]
        c3data = bdfh.BDFsignals[m:n, 501:750][:]
        c4data = bdfh.BDFsignals[m:n, 751:1000][:]
        Fp1T3 = c2data .- c1data
        Fp2T4 = c4data .- c3data
        Fp1T3 = EDFPlus.lowpassfilter(Fp1T3, 250, 40.0)
        Fp2T4 = EDFPlus.lowpassfilter(Fp2T4, 250, 40.0)
        Fp1T3 = EDFPlus.highpassfilter(Fp1T3, 250, 0.5)
        Fp2T4 = EDFPlus.highpassfilter(Fp2T4, 250, 0.5)
        ydata = [Fp1T3, Fp2T4]
        timepoints = linspace(0.0, PLOT_INTERVAL, length(Fp1T3))
        
        # detach plotting, return quickly now so as to avoid dropped packets
        @async begin
            fig = Figure()
            ticks = collect(timepoints[1]:1:timepoints[end])
            ax1 = Axis(fig[1, 1];
                       title="Interval from $(pcount-PLOT_INTERVAL) to $pcount",
                       xticks=ticks,
                       yticksvisible=false, yticklabelsvisible=false,
                       ylabel="Fp1-T3")
            ax2 = Axis(fig[2, 1];
                       xticks=ticks,
                       yticksvisible=false, yticklabelsvisible=false,
                       ylabel="Fp2-T4")
            hidexdecorations!(ax1)
            lines!(ax1, timepoints, Fp1T3)
            lines!(ax2, timepoints, Fp2T4)
            display(fig)
        end
    end
end


makeganglionbdfplus("examplefile.bdf", boardIP, myIP, 120,
                             idfile=idfile, inspector=plottwobipolars)
