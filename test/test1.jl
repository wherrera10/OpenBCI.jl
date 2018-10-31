using OpenBCI

boardIP = "192.168.1.2"  // change for your board
myIP = "192.168.1.1"     // change for your host
idfile = "patientdata.json"

OpenBCI.makeganglionbdfplus("testfile.bdf", boardIP, myIP, 30, idfile=idfile)


true

