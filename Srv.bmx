Framework BRL.ThreadPool
Import "ServeThread.bmx"

Local Port:Int = 80

Local Socket:TSocket = CreateTCPSocket()
If Not BindSocket(Socket, Port) Then RuntimeError("Failed to bind to port " + Port + "!")

SocketListen(Socket)

Local ThreadPool:TThreadPoolExecutor = TThreadPoolExecutor.newFixedThreadPool(128) ' Should be large to accomodate some threads sleeping in keep-alive wait
Local ConnectionsTotal:ULong

Print "Server is up on port " + Port 

While True
	' You can enable blocking mode on SocketAccept() by passing -1 as timeout
	' You can also set it to some amount of time (in ms), if you still want the non-blocking mode
	Local SocketConnection:TSocket = SocketAccept(Socket, -1)

	If SocketConnection
		Local Parameters:ServeThreadParameters = New ServeThreadParameters
		
		Parameters.ClientSocket = SocketConnection
		
		Parameters.Timeout = 15000 ' This is an inactivity timeout. If the thread keeps getting requests every so often, it could keep running forever. Perhaps there should be an age limit that doesn't take activity into account?
		Parameters.PipeTimeout = 250 ' Don't wait much for pipes
		Parameters.PayloadTimeout = 3000 ' For how long the server will wait for payload to go through
		
		Parameters.BytesPerCycle = 64*1024 ' Transmit buffer size. I believe the optimal value is (System RAM / 65536), but not less than the filesystem cluster size 
		Parameters.CompressionSizeLimit = 4 * 1024 * 1024 ' Compression size limit of 4MB; Trying to compress large files can cause noticeable delays
		Parameters.EnableHostnameLookup = 0
		Parameters.EnableCompression = 1
		Parameters.EnableCaching = 1
		Parameters.CachingLocation = "./"
		Parameters.RequestPayloadCompressionAllowed = 1
		Parameters.RequestPayloadLengthLimit = 8*1024*1024 ' Limit the payload that the client can send to 8MB
		Parameters.FilesizeAfterUpdateLimit = 16*1024*1024 ' May not grow files to be larger than 16MB
		Parameters.KeepAliveAllowed = 1
		
		Parameters.UploadsAllowed = 1
		Parameters.DeletesAllowed = 1
		Parameters.RangesAllowed = 1
		Parameters.MovesAllowed = 1
		
		Parameters.WebDAVAllowed = 1
		Parameters.ConnectionID = ConnectionsTotal
		
		Local Task:TServeThread = New TServeThread(Parameters)
		
		ThreadPool.Execute(Task)
		ConnectionsTotal :+ 1
	End If
	
Wend
