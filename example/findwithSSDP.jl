# Uses SSDP to locate the IP for the OpenBCI WiFi board if it is
# functioning on the local network.

using UPnPClient

const ARDUINOMATCH = "SERVER: Arduino.+(http://[^/]+)/description"
println("The OpenBCI board responds at URI: ", probe_network(ARDUINOMATCH)[1])
