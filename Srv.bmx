Framework BRL.Threads
Import "ServeThread.bmx"

Local Port:Int = 80

Local Socket:TSocket = CreateTCPSocket()
If Not BindSocket(Socket, Port) Then RuntimeError("Failed to bind to port " + Port + "!")

SocketListen(Socket)

Local SocketConnection:TSocket
Local Parameters:ServeThreadParameters

Local ThreadsTotal:ULong

Print "Server is up on port " + Port 

While True
	' You can enable blocking mode on SocketAccept() by passing -1 as timeout
	' You can also set it to some amount of time (in ms), if you still want the non-blocking mode
	SocketConnection = SocketAccept(Socket, -1)

	If SocketConnection
		Parameters = New ServeThreadParameters
		
		Parameters.ClientSocket = SocketConnection
		
		Parameters.Timeout = 15000 ' This is an inactivity timeout. If the thread keeps getting requests every so often, it could keep running forever. Perhaps there should be an age limit that doesn't take activity into account?
		Parameters.PipeTimeout = 250 ' Don't wait much for pipes
		Parameters.PayloadTimeout = 3000 ' For how long the server will wait for payload to go through
		
		Parameters.BytesPerCycle = 16*1024 '16 * 1024
		Parameters.CompressionSizeLimit = 4 * 1024 * 1024 ' Compression size limit of 4MB; Trying to compress large files can cause noticeable delays
		Parameters.EnableHostnameLookup = 0
		Parameters.EnableCompression = 1
		Parameters.EnableCaching = 1
		Parameters.CachingLocation = "./"
		Parameters.RequestPayloadLengthLimit = 8*1024*1024 ' Limit the payload that the client can send to 8MB
		Parameters.FilesizeAfterUpdateLimit = 16*1024*1024 ' May not grow files to be larger than 16MB
		Parameters.KeepAliveAllowed = 1
		
		Parameters.UploadsAllowed = 1
		Parameters.DeletesAllowed = 1
		Parameters.RangesAllowed = 1
		Parameters.MovesAllowed = 1
		
		Parameters.WebDAVAllowed = 1
		Parameters.ThreadID = ThreadsTotal
		
		CreateThread(ServeThread, Parameters)
		ThreadsTotal :+ 1
	End If
	
Wend
