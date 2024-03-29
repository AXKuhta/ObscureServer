SuperStrict

Import BRL.Retro
Import "Utils.bmx"
Import "DataLevel.bmx"
Import "ProtoHTTP.bmx"
Import "ProtoWebDAV.bmx"

Type TServeThread Extends TRunnable
	Field Parameters:ServeThreadParameters

	Method New(Parameters:ServeThreadParameters)
		Self.Parameters = Parameters
	End Method
	
	Method Run()
		set_thread_parameters(Parameters)
		
		Local ThreadStartupMS:ULong = MilliSecs()
		Local ThreadStartupuS:ULong = microseconds()
		
		LoggedPrint(" = = = New client = = = ")
		
		PrintClientIP(Parameters.ClientSocket, Parameters.EnableHostnameLookup)
			
		Parameters.ThreadStartupMS = ThreadStartupMS
		Parameters.ThreadLastActivityMS = ThreadStartupMS
		
		Parameters.ClientStream:TStream = CreateSocketStream(Parameters.ClientSocket)
		
		If Not Parameters.ClientStream
			LoggedPrint("ABORTING: failed to create client stream.")
			Return
		End If
		
		' Main serving loop. We will return from this function when the client has disconnected or timed out.
		WaitRequests(Parameters)
		
		CloseConnection(Parameters)
			
		LoggedPrint("Finished. Ran for " + (microseconds() - ThreadStartupuS) + " uSec. / " + ((microseconds() - ThreadStartupuS) / 1000000.0) + " Sec.")
		LoggedPrint(" = = = = = = = = = = = =")
		
		Return
	End Method
End Type

Function WaitRequests(Parameters:ServeThreadParameters)
	Local ClientSocket:TSocket = Parameters.ClientSocket
	Local ClientStream:TStream = Parameters.ClientStream
	Local ParsedRequest:HTTPRequestStruct
	Local Header:String
	Local PayloadPresent:Int = 0
	Local PayloadLength:Long
	Local i:Int

	Repeat
		LoggedPrint("Waiting for request.")
		
		Repeat
			If RunAbilityCheck(Parameters, 1) = 0 Then Return
			If SocketReadAvail(ClientSocket) > 0 Then Exit
			ClientSocket.Recv(Null, 0)
		Forever
		
		LoggedPrint("Got request.")
		Parameters.ThreadLastActivityMS = MilliSecs()
		
		' = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =
		
		Parameters.KeepAliveEnabled = 0 ' Zero these out just in case
		Parameters.ExpectsContinue = 0
		Parameters.EncodingMode = ""
		
		PayloadLength = 0
		i = 0
		
		
		' Parse request
		ParsedRequest = ParseRequest(ReadLine(ClientStream))
		
		If Not ParsedRequest
			LoggedPrint("ABORTING: Failed to parse request. Probably not HTTP.")
			Return
		End If
		
		If ParsedRequest.Version = "HTTP/1.1" And Parameters.KeepAliveAllowed = 1
			LoggedPrint("Keep-alive enabled per protocol version.")
			Parameters.KeepAliveEnabled = 1
		End If
		
		
		' Parse headers
		Repeat
			Header = ReadLine(ClientStream)
			
			'If Len(Header) > 2048
			'	LoggedPrint("ABORTING: Header line too long.")
			'	Return
			'End If
			
			Select Lower(Header.Split(":")[0])
				Case "connection"
					Parameters.ConnectionFlags = ExtractHeaderFlags(Header)
					
				Case "content-length"
					PayloadLength = Long(ExtractHeaderFlags(Header)[0])
					PayloadPresent = 1
					LoggedPrint("Got a hint for payload length: " + PayloadLength)

				Case "accept-encoding"
					If IsInArray("gzip", ExtractHeaderFlags(Header)) Then Parameters.EncodingMode = "gzip"
					If IsInArray("zstd", ExtractHeaderFlags(Header)) Then Parameters.EncodingMode = "zstd"
					
				Case "content-encoding"
					Parameters.RequestPayloadEncodingMode = ExtractHeaderFlags(Header)[0]
					
				Case "destination"
					ParsedRequest.Destination = ParseDestination(ExtractHeaderFlags(Header)[0])
					LoggedPrint("Got destination: " + ParsedRequest.Destination)
				
				Case "expect"
					If IsInArray("100-continue", ExtractHeaderFlags(Header)) Then Parameters.ExpectsContinue = 1
					LoggedPrint("Got a hint for expected response: " + ExtractHeaderFlags(Header)[0] + ".")
					
				Case "range"
					ParsedRequest.RangeStart = ExtractRanges(Header)[0]
					ParsedRequest.RangeStop = ExtractRanges(Header)[1]
					LoggedPrint("Got ranges: " + ParsedRequest.RangeStart + "-" + ParsedRequest.RangeStop)
					
				
				
				Default
					' If something doesn't work, uncomment this
					' Perhaps there's some problem with case sensetivity happening
					' LoggedPrint("Unknown header: " + Header)
			End Select
						
			i :+ 1
			If Not RunAbilityCheck(Parameters) Then Return
		Until Header = ""
		
		
		If IsInArray("keep-alive", Parameters.ConnectionFlags) And Parameters.KeepAliveAllowed = 1
			LoggedPrint("Keep-alive enabled per header.")
			Parameters.KeepAliveEnabled = 1
		End If
		
		If IsInArray("te", Parameters.ConnectionFlags)
			LoggedPrint("Clients wants Transfer-Mode header. Ignoring it.")
		End If
		
		' = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =
		
		If SocketReadAvail(ClientSocket) > 0 And PayloadPresent = 0
			LoggedPrint("There's "+SocketReadAvail(ClientSocket)+" bytes of payload within the request but no Content-Length header.")
		End If
		
		If PayloadLength > Parameters.RequestPayloadLengthLimit
			' This situation can occur if a client tried to upload a file that's too big
			' We'll tell them that there's a problem and bail
			LoggedPrint("Error 413. Request payload is over the limit: " + PayloadLength + " bytes vs " + Parameters.RequestPayloadLengthLimit + " bytes.")
			SendError(413, Parameters) 
			Return
		End If
		
		If Parameters.ExpectsContinue
			' If we are needed to, say that everything is looking good
			' CarotDAV uses 100-Continue during file uploads, though it will still work fine even if
			' you remove this code block completely
			SendStatus(100, Parameters) 
		End If
			
		If PayloadLength > 0
			ParsedRequest.PayloadSize = PayloadLength
		End If
		
		' = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =
		
		ParsedRequest.Target = URLDecode(ParsedRequest.Target) ' Turns "%20" into spaces
		
		If (ParsedRequest.Target.Contains("//") Or ParsedRequest.Target.Contains(".."))
			LoggedPrint("ABORTING: Suspicious request target.")
			Return
		End If
				
		Select ParsedRequest.Action
			Case "GET", "OPTIONS", "HEAD", "POST", "PUT", "DELETE", "MOVE"
				ProcessHTTPRequest(ParsedRequest, Parameters)
				
			Case "PROPFIND", "PROPPATCH"
				ProcessWebDAVRequest(ParsedRequest, Parameters)
								
			Default ' 405 Method not supported
				LoggedPrint("Error 405. Method ["+ParsedRequest.Action+"] not supported.")
				SendError(405, Parameters)
								
		End Select
		
		' = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =

	Until Parameters.KeepAliveEnabled = 0 Or RunAbilityCheck(Parameters) = 0
End Function




