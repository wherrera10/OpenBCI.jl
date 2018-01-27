#=
@Version: 0.01
@Author: William Herrera
@Copyright: 2018 William Herrera
@Created: 24 Jan 2018
@Purpose: EEG file OpenBCI Ganglion view data example
=#

using OpenBCI_WiFi
using EDFPlus
using Plots
pyplot()
using PyPlot
# ENV["MPLBACKEND"]="qt4agg" # set backend for PyPlot as needed


boardIP = "192.168.1.23"
myIP = "192.168.1.1"
idfile = "../test/patientdata.json"

const PLOTINTERVAL = 10


function plottwobipolars(bdfh, pcount, maxpackets)
    if pcount > PLOTINTERVAL && pcount % PLOTINTERVAL == 1
        c1data = bdfh.BDFsignals[pcount-PLOTINTERVAL:pcount, 1:250][:]
        c2data = bdfh.BDFsignals[pcount-PLOTINTERVAL:pcount, 251:500][:]
        c3data = bdfh.BDFsignals[pcount-PLOTINTERVAL:pcount, 501:750][:]
        c4data = bdfh.BDFsignals[pcount-PLOTINTERVAL:pcount, 751:1000][:]
        Fp1T3 = c2data .- c1data
        Fp2T4 = c4data .- c3data
        Fp1T3 = EDFPlus.lowpassfilter(Fp1T3, 250)
        Fp2T4 = EDFPlus.lowpassfilter(Fp2T4, 250)
        Fp1T3 = EDFPlus.highpassfilter(Fp1T3, 250)
        Fp2T4 = EDFPlus.highpassfilter(Fp2T4, 250)
        ydata = [Fp1T3, Fp2T4]
        timepoints = linspace(0.0, PLOTINTERVAL, length(Fp1T3))
        
        # detach plotting, return quickly now so as to avoid dropped packets
        @async(begin
        plt = Plots.plot(timepoints, ydata, layout=(2,1),
                   xticks=collect(timepoints[1]:1:timepoints[end]), 
                   yticks=false, legend=false, title="Interval from $(pcount-PLOTINTERVAL) to $pcount")
        plt[1][:xaxis][:showaxis] = false
        Plots.plot!(yaxis=true, tight_layout=true, ylabel = "Fp1-T3", subplot=1)
        Plots.plot!(yaxis=true, tight_layout=true, ylabel = "Fp2-T4", subplot=2)
        PyPlot.display(plt)
        end)
    end
end


OpenBCI_WiFi.makeganglionbdfplus("examplefile.bdf", boardIP, myIP, 120,
                             idfile=idfile, inspector=plottwobipolars)

