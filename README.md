# OpenBCIWiFi.jl
Julia interface to the WiFi connected OpenBCI EEG hardware.


Neither OpenBCI_WiFI.jl nor its dependency EDFPlus.jl are currently registered packages. 

To install from a Julia REPL command line session, type:

using Pkg
Pkg.add(PackageSpec(url="http://github.com/wherrera10/EDFPlus.jl"))
Pkg.add(PackageSpec(url="http://github.com/wherrera10/OpenBCIWiFi.jl"))
