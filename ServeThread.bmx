Import BRL.Retro
Import "Utils.bmx"
Import "DataLevel.bmx"
Import "ProtoHTTP.bmx"
Import "ProtoWebDAV.bmx"

Function ServeThread:Object(ParametersObject:Object)
	Local Parameters:ServeThreadParameters = ServeThreadParameters(ParametersObject)
	Local ThreadStartupMS:ULong = MilliSecs()
	Local ThreadStartupuS:ULong = microseconds()
	
	LoggedPrint(" = = = New client = = = ", Parameters.ThreadID)
	
	PrintClientIP(Parameters.ClientSocket, Parameters.ThreadID, Parameters.EnableHostnameLookup)
		
	Parameters.ThreadStartupMS = ThreadStartupMS
	Parameters.ThreadLastActivityMS = ThreadStartupMS
	
	Parameters.ClientStream:TStream = CreateSocketStream(Parameters.ClientSocket)
	
	If Not Parameters.ClientStream
		LoggedPrint("ABORTING: failed to create client stream.", Parameters.ThreadID)
		Return
	End If
	
	' Main serving loop. We will return from this function when the client has disconnected or timed out.
	WaitRequests(Parameters)
	
	CloseConnection(Parameters)
		
	LoggedPrint("Finished. Ran for " + (microseconds() - ThreadStartupuS) + " uSec. / " + ((microseconds() - ThreadStartupuS) / 1000000.0) + " Sec.", Parameters.ThreadID)
	LoggedPrint(" = = = = = = = = = = = =", Parameters.ThreadID)
End Function


Function WaitRequests(Parameters:ServeThreadParameters)
	Local ThreadID:ULong = Parameters.ThreadID
	Local ClientSocket:TSocket = Parameters.ClientSocket
	Local ClientStream:TStream = Parameters.ClientStream
	Local ParsedRequest:HTTPRequestStruct
	Local Headers:String[]
	Local Payload:Byte[]
	Local PayloadLength:Long
	Local i:Int

	Repeat
		LoggedPrint("Waiting for request.", ThreadID)
		
		Repeat
			If RunAbilityCheck(Parameters, 1) = 0 Then Return
			If SocketReadAvail(ClientSocket) > 0 Then Exit
			usleep(200) ' Take a 200 microsecond nap
		Forever
		
		LoggedPrint("Got request.", ThreadID)
		Parameters.ThreadLastActivityMS = MilliSecs()
		
		' = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =
		
		Parameters.KeepAliveEnabled = 0 ' Zero these out just in case
		Parameters.ExpectsContinue = 0
		Parameters.EncodingMode = ""
		
		ParsedRequest.Payload = Null ' Zero out the payload pointer
		Headers = Null
		PayloadLength = 0
		i = 0
		
		ParsedRequest = ParseRequest(ReadLine(ClientStream))
		
		If Not ParsedRequest
			LoggedPrint("ABORTING: Failed to parse request. Probably not HTTP.", ThreadID)
			Return
		End If
		
		Repeat
			If RunAbilityCheck(Parameters) = 0 Then Return
			Headers = Headers[..i + 1]
			Headers[i] = ReadLine(ClientStream)
			
			'If Len(Headers[i]) > 2048
			'	LoggedPrint("ABORTING: Header line too long.", ThreadID)
			'	Return
			'End If
			
			Select Lower(Headers[i].Split(":")[0])
				Case "connection"
					Parameters.ConnectionFlags = ExtractHeaderFlags(Headers[i])
					
				Case "content-length"
					PayloadLength = Long(ExtractHeaderFlags(Headers[i])[0])
					LoggedPrint("Got a hint for payload length: " + PayloadLength, ThreadID)

				Case "accept-encoding"
					If IsInArray("gzip", ExtractHeaderFlags(Headers[i])) Then Parameters.EncodingMode = "gzip"
					If IsInArray("zstd", ExtractHeaderFlags(Headers[i])) Then Parameters.EncodingMode = "zstd"
					
				Case "destination"
					ParsedRequest.Destination = ParseDestination(ExtractHeaderFlags(Headers[i])[0])
					LoggedPrint("Got destination: " + ParsedRequest.Destination, ThreadID)
				
				Case "expect"
					If IsInArray("100-continue", ExtractHeaderFlags(Headers[i])) Then Parameters.ExpectsContinue = 1
					LoggedPrint("Got a hint for expected response: " + ExtractHeaderFlags(Headers[i])[0] + ".", ThreadID)
					
				Case "range"
					ParsedRequest.RangeStart = ExtractRanges(Headers[i])[0]
					ParsedRequest.RangeStop = ExtractRanges(Headers[i])[1]
					LoggedPrint("Got ranges: " + ParsedRequest.RangeStart + "-" + ParsedRequest.RangeStop, ThreadID)
				
				
				Default
					' If something doesn't work, uncomment this
					' Perhaps there's some problem with case sensetivity happening
					' LoggedPrint("Unknown header: " + Header[i], ThreadID)
			End Select
						
			i :+ 1
		Until (Headers[i - 1] = "") Or (SocketReadAvail(ClientSocket) = 0)
		
		
		If IsInArray("keep-alive", Parameters.ConnectionFlags) And (Parameters.KeepAliveAllowed = 1)
			LoggedPrint("Keep-alive mode enabled.", ThreadID)
			Parameters.KeepAliveEnabled = 1
		End If
		
		If IsInArray("te", Parameters.ConnectionFlags)
			LoggedPrint("Clients wants Transfer-Mode header. Ignoring it.", ThreadID)
		End If
		
		' = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =
		
		If (SocketReadAvail(ClientSocket) > 0) And (PayloadLength = 0)
			LoggedPrint("There's "+SocketReadAvail(ClientSocket)+" bytes of payload within the request but no Content-Length header.", ThreadID)
			PayloadLength = SocketReadAvail(ClientSocket) ' We'll set the length ourselves if that happened
		End If
		
		If PayloadLength > Parameters.RequestPayloadLengthLimit
			' This situation can occur if a client tried to upload a file that's too big
			' We'll tell them that there's a problem and bail
			LoggedPrint("Request payload is over the limit: " + PayloadLength + " bytes vs " + Parameters.RequestPayloadLengthLimit + " bytes. Aborting.", ThreadID)
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
			ParsedRequest.PayloadLength = PayloadLength
			ParsedRequest.Payload = ReceivePayload(PayloadLength, Parameters)
		End If

		' = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =
		
		ParsedRequest.Target = URLDecode(ParsedRequest.Target) ' Turns "%20" into spaces
		
		If (ParsedRequest.Target.Contains("//") Or ParsedRequest.Target.Contains(".."))
			LoggedPrint("ABORTING: Suspicious request target.", Parameters.ThreadID)
			Return
		End If
				
		Select ParsedRequest.Action
			Case "GET", "OPTIONS", "HEAD", "POST", "PUT", "DELETE", "MOVE"
				ProcessHTTPRequest(ParsedRequest, Parameters)
				
			Case "PROPFIND", "PROPPATCH"
				ProcessWebDAVRequest(ParsedRequest, Parameters)
								
			Default ' 405 Method not supported
				SendError(405, Parameters)
								
		End Select
		
		' Free the payload memory if it was ever allocated
		If ParsedRequest.Payload Then MemFree(ParsedRequest.Payload)
		
		' = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =

	Until ((Parameters.KeepAliveEnabled = 0) Or (RunAbilityCheck(Parameters) = 0))
End Function




