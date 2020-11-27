Import BAH.MbedTLS
Import BRL.Socket

Import BRL.StandardIO

' Lowest level HTTPS-related functionality

' Interface between mbedtls and BlitzMax sockets
' Server-mode only
Type TSSLSocket Extends TSocket

?Ptr64
	Method Send:Long( buf:Byte Ptr, count:Size_T, flags:Int = 0 ) Override
?Not ptr64
	Method Send:Int( buf:Byte Ptr, count:Size_T, flags:Int = 0 ) Override
?
		Local Status:Int = mbedtls_ssl.Write(buf, count)
		
		While Status < 0
			If Status = MBEDTLS_ERR_SSL_WANT_READ Or Status = MBEDTLS_ERR_SSL_WANT_WRITE
				Status = mbedtls_ssl.Write(buf, count)
			ElseIf Status = MBEDTLS_ERR_NET_CONN_RESET
				Print "TSSLSocket: Connection reset"
				_connected = 0
				Return 0
			Else
				Print "TSSLSocket: send error: " + MBEDTLSError(Status)
				_connected = 0
				Return 0
			End If
		Wend

		Return Status
	End Method

?ptr64
	Method Recv:Long( buf:Byte Ptr, count:Size_T, flags:Int = 0 ) Override
?Not ptr64
	Method Recv:Int( buf:Byte Ptr, count:Size_T, flags:Int = 0 ) Override
?
		Local Status:Int = mbedtls_ssl.Read(buf, count)
		
		While Status < 0
			If Status = MBEDTLS_ERR_SSL_WANT_READ Or Status = MBEDTLS_ERR_SSL_WANT_WRITE
				Status = mbedtls_ssl.Read(buf, count)
			ElseIf Status = MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY
				Print "TSSLSocket: Connection was closed gracefully"
				_connected = 0
				Return 0
			ElseIf Status = MBEDTLS_ERR_NET_CONN_RESET
				Print "TSSLSocket: Connection reset"
				_connected = 0
				Return 0
			Else
				Print "TSSLSocket: recv error: " + MBEDTLSError(Status)
				_connected = 0
				Return 0
			End If
		Wend
		
		Return Status
	End Method
		
	' Unique flavor of create function that takes the port number (not an Override)
	' Binding not required afterwards
	Function Create:TSSLSocket( Port:Int )
		Local Socket:TSSLSocket = New TSSLSocket
		
		sslsocket_mbedtls_init(Socket)
		sslsocket_mbedtls_test_cert_parse(Socket)
		sslsocket_mbedtls_test_pkey_parse(Socket)
		sslsocket_mbedtls_seed_rng(Socket)
		
		sslsocket_mbedtls_bind(Socket, Port)
		
		sslsocket_mbedtls_setup_ssl(Socket) ' In mainline this comes after the socket accept
		
		Return Socket
	End Function
	
	' Override of the Accept Method -- has to retain exactly the same arguments
	Method Accept:TSSLSocket( timeout:Int, storage:TSockaddrStorage ) Override
		Local ClientIP:String
		Local Status:Int
		
		
		' Create a new socket for the client comms
		Local NewSocket:TSSLSocket = New TSSLSocket
		
		' Minimal initialization
		NewSocket.mbedtls_client_socket = New TNetContext.Create()
		NewSocket.mbedtls_config = mbedtls_config
		NewSocket.mbedtls_ssl = New TSSLContext.Create()
		
		
		Status = mbedtls_listen_socket.Accept(NewSocket.mbedtls_client_socket, ClientIP)
		
		If Status
			RuntimeError "TNetContextAccept.Accept() error: " + Status
		End If
		
		
		NewSocket._remoteIp = ClientIP
		NewSocket._connected = 1
				
		' Let the new socket set up SSL by itself
		' Bail out if that fails
		If Not NewSocket.SelfSetup()
			NewSocket.Close()
			Return Null
		End If
		
		' Return it
		Return NewSocket
	End Method
	
	' Returns 0 on handshake failure
	' Returns 1 on success
	Method SelfSetup()
		Local Status:Int = mbedtls_ssl.Setup(mbedtls_config)
		
		If Status
			RuntimeError "TSSLContext.Setup() error: " + Status
		End If 
		
		mbedtls_ssl.SetBio(mbedtls_client_socket, NetSend, NetRecv, Null)
		
		Status = mbedtls_ssl.Handshake()
		
		' A handshake could span many operations while connection parameters are agreed upon
		' We have to check for WANT_READ and WANT_WRITE statuses and allow the loop to continue
		While Status
		
			' Error out on unknown status
			If Status <> MBEDTLS_ERR_SSL_WANT_READ And Status <> MBEDTLS_ERR_SSL_WANT_WRITE
				Print "TSSLSocket: handshake error: " + MBEDTLSError(Status)
				Return Null
			End If
			
			Status = mbedtls_ssl.Handshake()
		End While
		
		Return 1
	End Method
	
	Method RemoteIp:String() Override
		Return _remoteIP
	End Method

	Method Connected() Override
		Return _connected
	End Method
	
	Method ReadAvail:Int() Override
		Local Status:Int
		
		' Attempt to push the SSL decoder forward only if raw data pending
		Status = mbedtls_client_socket.Poll(MBEDTLS_NET_POLL_READ, Null)
		
		If Status < 0
			Print "TSSLSocket: polling error: " + MBEDTLSError(Status)
			_connected = 0
			Return 0
		End If
		
		If Status > 0
			' Alright, there's some raw data pending
			' The loop in Recv() should force it to be decoded
			Recv(Null, 0)
			
			If _connected = 0 Then Return 0
		End If
				
		Return mbedtls_ssl.GetBytesAvail()
	End Method
	
	Method Close() Override
		Local Status:Int
		
		If _connected = 1
			Status = mbedtls_ssl.CloseNotify()
			
			If Status < 0
				Print "TSSLSocket: error while closing the ssl session: " + MBEDTLSError(Status)
			End If
		End If
		
		_connected = 0
	End Method	
	
		
	Field mbedtls_listen_socket:TNetContext
	Field mbedtls_client_socket:TNetContext
	
	Field mbedtls_ssl:TSSLContext
	Field mbedtls_config:TSSLConfig
	
	Field mbedtls_cert:TX509Cert
	Field mbedtls_pk:TPkContext
	
	Field mbedtls_entropy:TEntropyContext
	Field mbedtls_rctx:TRandContext
	
	Field _connected:Int
	
	
	' Wrappers with error handling
	' =================================================================
	' Data structure initialization
	Function sslsocket_mbedtls_init(Socket:TSSLSocket)
		Socket.mbedtls_ssl = New TSSLContext.Create()
		Socket.mbedtls_config = New TSSLConfig.Create()
		
		Socket.mbedtls_cert = New TX509Cert.Create()
		Socket.mbedtls_pk = New TPkContext.Create()
				
		Socket.mbedtls_listen_socket = New TNetContext.Create()
		
		Socket.mbedtls_entropy = New TEntropyContext.Create()
		Socket.mbedtls_rctx = New TRandContext.Create()
	End Function
	
	' Parse the embedded test certificate
	Function sslsocket_mbedtls_test_cert_parse(Socket:TSSLSocket)
		Local Status:Int
		
		Status = Socket.mbedtls_cert.Parse(testServerCertificate, testServerCertificateLength)
		
		If Status
			RuntimeError "TX509Cert.Parse() error: " + Status
		End If
		
		Status = Socket.mbedtls_cert.Parse(testCaCertificatePem(), testCaCertificatePemLength)
		
		If Status
			RuntimeError "TX509Cert.Parse() pem error: " + Status
		End If
	End Function
	
	' Parse the embedded test RSA key
	Function sslsocket_mbedtls_test_pkey_parse(Socket:TSSLSocket)
		Local Status:Int = Socket.mbedtls_pk.ParseKey(testServerKey, testServerKeyLength)
		
		If Status
			RuntimeError "TPkContext.ParseKey() error: " + Status
		End If
	End Function
	
	' Bind the listening socket
	Function sslsocket_mbedtls_bind(Socket:TSSLSocket, Port:String)
		Local Status:Int = Socket.mbedtls_listen_socket.Bind("192.168.1.101", Port, MBEDTLS_NET_PROTO_TCP)
		
		If Status
			RuntimeError "TNetContext.Bind() error: " + Status
		End If
	End Function
	
	' Seed the random number generator
	Function sslsocket_mbedtls_seed_rng(Socket:TSSLSocket)
		Local Status:Int = Socket.mbedtls_rctx.Seed(EntropyFunc, Socket.mbedtls_entropy)
		
		If Status
			RuntimeError "TEntropyContext.Seed() error: " + Status
		End If
	End Function
	
	' Populate the config structure and setup SSL
	Function sslsocket_mbedtls_setup_ssl(Socket:TSSLSocket)
		Local Status:Int
		
		Status = Socket.mbedtls_config.Defaults(MBEDTLS_SSL_IS_SERVER, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT)
		
		If Status
			RuntimeError "TSSLConfig.Defaults() error: " + Status
		End If
		
		Socket.mbedtls_config.RNG(RandomFunc, Socket.mbedtls_rctx)
		Socket.mbedtls_config.DBG(MBedSSLDebug, Null)
		Socket.mbedtls_config.SetDebugThreshold(1)
		
		Socket.mbedtls_config.CaChain(Socket.mbedtls_cert.GetNext(), Null)
		
		Status = Socket.mbedtls_config.OwnCert(Socket.mbedtls_cert, Socket.mbedtls_pk)
		
		If Status
			RuntimeError "TSSLConfig.OwnCert() error: " + Status
		End If
	End Function
	' =================================================================
	

	' Stub out all the remaining socket functions/methods with an error
	' =================================================================	
	Method Bind:Int( localPort:Int, family:Int ) Override
		RuntimeError "Unimplemented: Bind( localPort:Int, family:Int )"
	End Method

	Method Bind:Int( info:TAddrInfo ) Override
		RuntimeError "Unimplemented: Bind( info:TAddrInfo )"
	End Method
	
	Method Connect:Int( AddrInfo:TAddrInfo ) Override
		RuntimeError "Unimplemented: Connect"
	End Method
	
	Method Listen:Int( backlog:Int ) Override
		RuntimeError "Unimplemented: Listen"
	End Method
		
	Method SetTCPNoDelay( enable ) Override
		RuntimeError "Unimplemented: SetTCPNoDelay"
	End Method
	
	Method SetSockOpt:Int(level:Int, optname:Int, enable:Int) Override
		RuntimeError "Unimplemented: SetSockOpt"
	End Method
	
	Method Socket:Int() Override
		RuntimeError "Unimplemented: Socket"
	End Method
	
	Method LocalIp:String() Override
		RuntimeError "Unimplemented: LocalIp"
	End Method
	
	Method LocalPort:Int() Override
		RuntimeError "Unimplemented: LocalPort"
	End Method
		
	Method RemotePort:Int() Override
		RuntimeError "Unimplemented: RemotePort"
	End Method
	
	Method UpdateLocalName:Int() Override
		RuntimeError "Unimplemented: UpdateLocalName"
	End Method
	
	Method UpdateRemoteName:Int() Override
		RuntimeError "Unimplemented: UpdateRemoteName"
	End Method
	
	Function Create:TSSLSocket( socket:Int, autoClose:Int ) Override
		RuntimeError "Unimplemented: Create( socket:Int, autoClose:Int )"
	End Function
	
	Function CreateUDP:TSocket(family:Int) Override
		RuntimeError "Unimplemented: UDP SSL not supported"
	End Function
	
	Function CreateTCP:TSocket(family:Int) Override
		RuntimeError "Unimplemented: use Create() instead of CreateTCP()"
	End Function

	Function Create:TSocket(info:TAddrInfo) Override
		RuntimeError "Unimplemented: Create(info:TAddrInfo)"
	End Function
	' =================================================================
	
End Type

Function MBedSSLDebug(ctx:Object, level:Int, file:String, line:Int, str:String)
	Print file + ":" + line + ":  " + str.Replace("~n","")
End Function

Function CreateSSLSocket:TSocket(Port:Int)
	Return TSSLSocket.Create(Port)
End Function
