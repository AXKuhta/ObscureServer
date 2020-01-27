Import PUB.Zlib
Import "Parameters.bmx"
Import "Utils.bmx"

' This file is for connection level control
' And functions that throw the bytes around


Import "PlatformSpecific.bmx"

Type MemoryVec
	Field Pointer:Byte Ptr
	Field Size:Size_T
End Type

Function SendFile(Filename:String, Parameters:ServeThreadParameters)
	Local FileStream:TStream = OpenFile(Filename)
	Local Size:Long = FileSize(Filename)
	
	LoggedPrint("Sending ["+Filename+"].", Parameters.ThreadID)
	
	WriteLine(Parameters.ClientStream, "Content-Length: " + Size)
	SendStreamToClient(FileStream, Size, Parameters)
	
	LoggedPrint("File ["+Filename+"] sent.", Parameters.ThreadID)
	CloseFile(FileStream)
End Function

Function SendFileSlice(Filename:String, Start:Long, Stop:Long, Parameters:ServeThreadParameters)
	Local FileStream:TStream = OpenFile(Filename)
	Local Size:Long
	
	If Stop = 0
		Stop = FileSize(Filename)
		Size = Stop - Start
	Else
		Size = Stop - Start + 1
	End If
	
	SeekStream(FileStream, Start)
	
	LoggedPrint("Sending a slice of ["+Filename+"]. Size: " + Size + " bytes.", Parameters.ThreadID)
	
	WriteLine(Parameters.ClientStream, "Content-Range: bytes " + Start + "-" + Stop  + "/" + FileSize(Filename))
	WriteLine(Parameters.ClientStream, "Content-Length: " + Size)
	SendStreamToClient(FileStream, Size, Parameters)
	
	LoggedPrint("Slice of ["+Filename+"] sent.", Parameters.ThreadID)
	CloseFile(FileStream)
End Function

Function SendCompressedFile(Filename:String, Parameters:ServeThreadParameters)
	Local ClientStream:TStream = Parameters.ClientStream
	Local FileStream:TStream
	Local Size:Long = FileSize(Filename)
	Local FilenameCached:String = Parameters.CachingLocation + Filename + "." + Parameters.EncodingMode + "c"
	Local FileCached:TStream
	
	If Parameters.EnableCaching = 1
		If FileType(FilenameCached)
			If FileTime(Filename) < FileTime(FilenameCached)
				LoggedPrint("Cache hit.", Parameters.ThreadID)
				FileStream = OpenFile(FilenameCached)
				If FileStream
					WriteLine(ClientStream, "Content-Encoding: " + Parameters.EncodingMode)
					WriteLine(ClientStream, "Content-Length: " + FileSize(FilenameCached))
					
					SendStreamToClient(FileStream, FileSize(FilenameCached), Parameters)
					LoggedPrint("File ["+Filename+"] sent from compression cache.", Parameters.ThreadID)
					CloseFile(FileStream)
					Return
				Else
					' If this happens, we will compress the file again instead of aborting
					LoggedPrint("Failed to open ["+FilenameCached+"]!", Parameters.ThreadID)
				End If
			Else
				LoggedPrint("Cache misfire (Outdated cache).", Parameters.ThreadID)
			End If
		Else
			LoggedPrint("Cache misfire (File wasn't cached).", Parameters.ThreadID)
		End If
	End If
	
	
	LoggedPrint("Compressing ["+Filename+"] ("+Parameters.EncodingMode+").", Parameters.ThreadID)
	FileStream = OpenFile(Filename)
	
	Local UncompressedMemory:Byte Ptr = MemAlloc(Size)
	FileStream.ReadBytes(UncompressedMemory, Size)	
	
	Local CompressedMemory:MemoryVec
	
	CompressedMemory = CompressMemory(UncompressedMemory, Size, Parameters)
		
	If CompressedMemory.Pointer
		WriteLine(ClientStream, "Content-Encoding: " + Parameters.EncodingMode)
		WriteLine(ClientStream, "Content-Length: " + CompressedMemory.Size)
		WriteLine(ClientStream, "")
	
		SendMemory(CompressedMemory.Pointer, CompressedMemory.Size, Parameters)
		
		LoggedPrint("File ["+Filename+"] sent.", Parameters.ThreadID)
	Else
		LoggedPrint("Failed to compress ["+Filename+"].", Parameters.ThreadID)
		MemFree(UncompressedMemory)	
		CloseFile(FileStream)
		Return
	End If
	
	If Parameters.EnableCaching = 1
		If Not ReadDir(Parameters.CachingLocation)
			LoggedPrint("Unable to read the caching directory! Assuming that it doesn't yet exist and trying to create it. TODO: Make this into an error for production, software shouldn't go around and create directories from a known malformed configuration. A pre-startup script should set up the caching directory if it needs to be set up.", Parameters.ThreadID)
			CreateDir(Parameters.CachingLocation)
		End If
		
		If ExtractDir(Filename) ' Check if the file was stored in an additional folder in the server root directory
			If Not ReadDir(Parameters.CachingLocation + ExtractDir(Filename))
				LoggedPrint("Creating a directory to cache a file.", Parameters.ThreadID)
				CreateDir(Parameters.CachingLocation + ExtractDir(Filename))
			End If
		End If
		
		FileCached = WriteFile(FilenameCached)
		If FileCached
			FileCached.WriteBytes(CompressedMemory.Pointer, CompressedMemory.Size)
			CloseFile(FileCached)
		Else
			LoggedPrint("Failed to write ["+FilenameCached+"]!", Parameters.ThreadID)
		End If
	End If

	MemFree(CompressedMemory.Pointer)
	MemFree(UncompressedMemory)
	
	CloseFile(FileStream)
End Function

' A function that sends compressed slices can't use caching!
Function SendCompressedFileSlice(Filename:String, Start:Long, Stop:Long, Parameters:ServeThreadParameters)
	Local ClientStream:TStream = Parameters.ClientStream
	Local CompressedMemory:MemoryVec
	Local FileStream:TStream
	Local Size:Size_T
	
	If Stop = 0
		Stop = FileSize(Filename)
		Size = Stop - Start
	Else
		Size = Stop - Start + 1
	End If
		
	LoggedPrint("Compressing a slice of ["+Filename+"] ("+Parameters.EncodingMode+").", Parameters.ThreadID)
	
	FileStream = OpenFile(Filename)
	SeekStream(FileStream, Start)
	
	Local UncompressedMemory:Byte Ptr = MemAlloc(Size)
	FileStream.ReadBytes(UncompressedMemory, Size)	
	
	WriteLine(Parameters.ClientStream, "Content-Range: bytes " + Start + "-" + Stop + "/" + FileSize(Filename))
	
	CompressedMemory = CompressMemory(UncompressedMemory, Size, Parameters)
	
	If CompressedMemory.Pointer
		WriteLine(ClientStream, "Content-Encoding: " + Parameters.EncodingMode)
		WriteLine(ClientStream, "Content-Length: " + CompressedMemory.Size)
		WriteLine(ClientStream, "")
	
		SendMemory(CompressedMemory.Pointer, CompressedMemory.Size, Parameters)
	
		LoggedPrint("Compressed slice of ["+Filename+"] sent.", Parameters.ThreadID)
	
		MemFree(CompressedMemory.Pointer)
	End If
	
	MemFree(UncompressedMemory)
	
	CloseFile(FileStream)
End Function

' The point of this function is to calculate the Content-Length before sending the payload text
' That's mandatory on a Keep-Alive connection so that the browser knows when to stop waiting for new data
Function SendText(PayloadText:String, Parameters:ServeThreadParameters)
	Local ClientStream:TStream = Parameters.ClientStream
	Local CompressedMemory:MemoryVec
	Local TextLength:Int = Len(PayloadText)
	Local ASCIIText:Byte Ptr
	
	If (TextLength > 256) And (TextLength < Parameters.CompressionSizeLimit) And (Parameters.EncodingMode <> "")
		LoggedPrint("Compressing text ("+Parameters.EncodingMode+").", Parameters.ThreadID)
				
		ASCIIText = PayloadText.toCString() ' Please note: problems with non-ASCII characters are likely to occur.
		
		CompressedMemory = CompressMemory(ASCIIText, TextLength, Parameters)
			
		If CompressedMemory.Pointer
			WriteLine(ClientStream, "Content-Encoding: " + Parameters.EncodingMode)
			WriteLine(ClientStream, "Content-Length: " + CompressedMemory.Size)
			WriteLine(ClientStream, "")
		
			SendMemory(CompressedMemory.Pointer, CompressedMemory.Size, Parameters)
		
			MemFree(CompressedMemory.Pointer)
		End If
			
		MemFree(ASCIIText)
	Else
		WriteLine(ClientStream, "Content-Length: " + TextLength)
		WriteLine(ClientStream, "")
		
		WriteLine(ClientStream, PayloadText)
	End If

End Function

'
Function SendMemory:Long(SourceMemory:Byte Ptr, Size:Size_T, Parameters:ServeThreadParameters)
	Local SentBytes:Long = 0
	Local BPC:Size_T = Parameters.BytesPerCycle
	Local Buffer:Byte Ptr = MemAlloc(BPC)
	Local Status:Int
		
	If Int(Size / Parameters.BytesPerCycle) = 0
		LoggedPrint("Data size is less than " + BPC + " bytes. Sending in a single cycle.", Parameters.ThreadID)
		Status = Parameters.ClientSocket.Send(SourceMemory, Size)
		SentBytes = Size
	Else
		LoggedPrint("Data size is " + Int(Size / BPC) + " times of " + BPC + " bytes. Sending in multiple cycles.", Parameters.ThreadID)
		For Local i=1 To Int(Size / BPC)
			If RunAbilityCheck(Parameters) = 0
				LoggedPrint("Connection or timeout failure. " + (Size - SentBytes) + " bytes left not sent.", Parameters.ThreadID)
				MemFree(Buffer)
				Return Null
			End If
						
			Status = Parameters.ClientSocket.Send(SourceMemory + SentBytes, BPC)
			SentBytes :+ BPC
		Next
		
		If SentBytes < Size
			If RunAbilityCheck(Parameters) = 0
				LoggedPrint("Connection or timeout failure. " + (Size - SentBytes) + " bytes left not sent.", Parameters.ThreadID)
				MemFree(Buffer)
				Return Null
			End If

			LoggedPrint("Sending remaining " + (Size - SentBytes) + " bytes.", Parameters.ThreadID)
			Status = Parameters.ClientSocket.Send(SourceMemory + SentBytes, (Size - SentBytes))
			' Be sure to MemFree your memory after finishing
		End If
	End If
	
	MemFree(Buffer)
	Return SentBytes
End Function

' This function will compress the supplied memory
' Returns null on failure
Function CompressMemory:MemoryVec(UncompressedMemory:Byte Ptr, Size:Size_T, Parameters:ServeThreadParameters)
	Local CompressedMemory:Byte Ptr = MemAlloc(Size + 64 * 1024) ' File size + additional 64KB of memory
	Local ClientStream:TStream = Parameters.ClientStream
	
	Local CompressedSize:UInt = Size + 64 * 1024
	Local CompressStatus:Int
	
	If Parameters.EncodingMode = "gzip"
		CompressStatus = GzipMemory(CompressedMemory, CompressedSize, UncompressedMemory, Size)
		If CompressStatus <> 0
			LoggedPrint("ABORTING: zlib error " + CompressStatus, Parameters.ThreadID)
			MemFree(CompressedMemory)
			Return Null
		End If
	ElseIf Parameters.EncodingMode = "zstd"
		CompressStatus = ZstdMemory(CompressedMemory, CompressedSize, UncompressedMemory, Size)
		If Not CompressStatus > 0
			LoggedPrint("ABORTING: zstd error " + CompressStatus, Parameters.ThreadID)
			MemFree(CompressedMemory)
			Return Null
		End If
		CompressedSize = CompressStatus ' Zstd (Or at least my version of it) returns the compressed size as a status
	End If
	
	LoggedPrint("Size win: " + (Size - Int(CompressedSize)) + " bytes (" + (100.0 - (Float(CompressedSize) / Float(Size)) * 100.0) + "% sheared off).", Parameters.ThreadID)
	
	Local Result:MemoryVec
	
	Result.Pointer = CompressedMemory
	Result.Size = CompressedSize
	
	Return Result
End Function

' This function is utilized to send files without compression
' When there's only a file stream and CopyBytes() is the most straightforward thing to do
Function SendStreamToClient(SourceStream:TStream, Size:Long, Parameters:ServeThreadParameters)
	Local SentBytes:Long = 0
	Local BPC:Size_T = Parameters.BytesPerCycle
	Local Buffer:Byte Ptr = MemAlloc(BPC)
	Local Status:Int
	
	WriteLine(Parameters.ClientStream, "") ' Assuming nothing sent a CRLF CRLF to the client up to this point
	
	If Int(Size / Parameters.BytesPerCycle) = 0
		LoggedPrint("File size is less than " + BPC + " bytes. Sending in a single cycle.", Parameters.ThreadID)
		SourceStream.Read(Buffer, Size)
		Status = Parameters.ClientSocket.Send(Buffer, Size)
	Else
		LoggedPrint("File size is " + Int(Size / BPC) + " times of " + BPC + " bytes. Sending in multiple cycles.", Parameters.ThreadID)
		For Local i=1 To Int(Size / BPC)		
			If RunAbilityCheck(Parameters) = 0
				LoggedPrint("Sending file failed. " + (Size - SentBytes) + " bytes left not sent.", Parameters.ThreadID)
				MemFree(Buffer)
				Return
			End If
			
			' TStream.Read() returns 0 if the end of file was reached, or the amount of bytes read if it wasn't
			SourceStream.Read(Buffer, BPC)
			Status = Parameters.ClientSocket.Send(Buffer, BPC)
			
			' Socket will return -1 if the send had failed. Otherwise it will return the amount of bytes sent.
			' LoggedPrint("TSocket.Send() status: " + Status, Parameters.ThreadID)
						
			SentBytes :+ BPC
		Next
		
		If SentBytes < Size
			If RunAbilityCheck(Parameters) = 0
				LoggedPrint("Sending file failed. " + (Size - SentBytes) + " bytes left not sent.", Parameters.ThreadID)
				MemFree(Buffer)
				Return
			End If

			LoggedPrint("Sending remaining " + (Size - SentBytes) + " bytes.", Parameters.ThreadID)
			SourceStream.Read(Buffer, (Size - SentBytes))
			Status = Parameters.ClientSocket.Send(Buffer, (Size - SentBytes))
		End If
	End If
	
	MemFree(Buffer)
End Function

Function ReceivePayload:Byte Ptr(PayloadLength:Long, Parameters:ServeThreadParameters)
	Local WaitStartMS:ULong = MilliSecs()
	Local BytesStored:Long
	Local ReadAvail:Long
	Local TimedOut:Int
	Local Memory:Byte Ptr = MemAlloc(PayloadLength)
	
	Repeat
		ReadAvail = SocketReadAvail(Parameters.ClientSocket)
	
		If ReadAvail = 0
			usleep(1)
		Else
			If (BytesStored + ReadAvail) > PayloadLength
				LoggedPrint("WARNING: Have more bytes to receive than advertised. Capping to the advertised value.", Parameters.ThreadID)
				ReadAvail = PayloadLength - BytesStored
			End If
			BytesStored :+ Parameters.ClientStream.Read(Memory + BytesStored, ReadAvail)
			WaitStartMS = MilliSecs() ' Reset the counter if some data went through
		End If 
		
		TimedOut = (MilliSecs() > (WaitStartMS + Parameters.PayloadTimeout))
	Until (BytesStored = PayloadLength) Or TimedOut
	
	If BytesStored < PayloadLength
		LoggedPrint("Received less bytes than advertised. Continuing anyway.", Parameters.ThreadID)
	End If
	
	If TimedOut
		LoggedPrint("Timed out while waiting for the payload to go through. "+(PayloadLength - BytesStored)+" bytes not received. Continuing anyway.", Parameters.ThreadID)
	End If

	Return Memory
End Function

' This function will create a new file and write data to it
' Returns 1 on success, 0 on failure
' TODO: Test what happens if there's no space left on the device
Function ReceiveFile(Filename:String, Data:Byte Ptr, DataLength:Long)
	Local OutputFile:TStream = WriteFile(Filename)
	
	If Not OutputFile Then Return 0
	
	OutputFile.Write(Data, DataLength)
	
	CloseFile(OutputFile)
	
	Return 1
End Function

' This function will add the data to the end of already existing file
' TODO: Test what happens if there's no space left on the device
Function UpdateFile(Filename:String, Data:Byte Ptr, DataLength:Long)
	Local OutputFile:TStream = OpenFile(Filename)
	
	If Not OutputFile Then Return 0
	
	SeekStream(OutputFile, StreamSize(OutputFile))
	OutputFile.Write(Data, DataLength)
	
	CloseFile(OutputFile)
	
	Return 1
End Function

Function RunAbilityCheck:Int(Parameters:ServeThreadParameters, EnableTimeout:Int = 0)
	Local InactiveTime:Long = MilliSecs() - Parameters.ThreadLastActivityMS
	
	If (InactiveTime > Parameters.Timeout) And (EnableTimeout = 1)
			LoggedPrint("Timed out.", Parameters.ThreadID)
			Return 0
	ElseIf Not SocketConnected(Parameters.ClientSocket)
			LoggedPrint("Client unexpectedly disconnected.", Parameters.ThreadID)
			Return 0
	End If
	
	Return 1
End Function

Function CloseConnection(Parameters:ServeThreadParameters)
	CloseStream(Parameters.ClientStream)
	CloseSocket(Parameters.ClientSocket)
End Function

