# Uses SSDP to locate the IP for the OpenBCI WiFi board if it is
# functioning on the local network.

using SSDPClient

const ARDUINOMATCH = "SERVER: Arduino.+(http://[^/]+)/description"
println("The OpenBCI board responds at URI: ", ssdpquery(ARDUINOMATCH)[1])
