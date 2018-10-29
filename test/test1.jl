using OpenBCIWiFi

boardIP = "192.168.1.23"
myIP = "192.168.1.1"
idfile = "patientdata.json"

OpenBCIWiFi.makeganglionbdfplus("testfile.bdf", boardIP, myIP, 30, idfile=idfile)


true

