using OpenBCI_WiFI.jl

# set these for your systems

boardIP = "192.168.1.25"
myIP = "192.168.1.1"
idfile = "patientdata.json"


makeganglionbdfplus("testfile.bdf", boardIP, myIP, idfile=idfile)


true
