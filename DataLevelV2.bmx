Import "PlatformSpecific.bmx"
Import "Parameters.bmx"
Import "Utils.bmx"

Function WFD(Stream:TStream)
	Stream.Read(Null, 0)
End Function

' Provides reception of individual bursts of data, ideal for event streams
' Passes data to Destination ASAP
' Receives at most Size number of bytes
' Returns number of bytes received
Function SocketReceive:Size_T(Destination:TStream, SocketStream:TSocketStream, Size:Size_T)
	Local Socket:TSocket = SocketStreamSocket(SocketStream)
	Local Buffer:Byte[4096]
	Local Total:Size_T = 0

	While Not Eof(SocketStream)
		Local Avail:Size_T = SocketReadAvail(Socket)
		Local Remains:Size_T = Size - Total

		If Remains = 0
			Exit
		End If

		If Avail = 0
			WFD(SocketStream)
			Continue
		End If
		
		If Avail > 4096
			Avail = 4096
		End If
		
		If Avail > Remains
			Avail = Remains
		End If

		SocketStream.Read(Buffer, Avail)
		Destination.Write(Buffer, Avail)
		
		Total :+ Avail
	Wend
	
	Return Total
End Function

Type MiniZDecodeAdapter Extends TStream
	Field Destination:TStream
	Field Stream:Byte Ptr
	Field Buffer:Byte[4096]
	Field Header:Int = 10
	Field CRC32:Int = 0
	Field Tail:Byte[]

	Method New(Destination:TStream)
		Stream = alloc_miniz_decoder(Buffer, 4096)
		Self.Destination = Destination
	End Method

	' Header trap
	Method Write:Long(Source:Byte Ptr, Size:Long)
		If Header > 0
			If Size > Header
				Local Result:Size_T = Write_(Source + Header, Size - Header)
				Header = 0
				Return Result
			Else
				Header :- Size
				Return Size
			End If
		Else
			Return Write_(Source, Size)
		End If
	End Method
	
	' Deflate
	Method Write_:Long(Source:Byte Ptr, Size:Long)
		Local Status:Int = provide_miniz_decoder_input(Stream, Source, Size)
		Local Pending:Size_T = harvest_miniz_output(Stream)
		
		CRC32 = mz_crc32( CRC32, Buffer, Pending )
		Destination.Write(Buffer, Pending)
		
		' Status 0		All data consumed, waiting for more
		' Status 1		End of bitstream
		' Status 3		Destination buffer saturated, flush until it is not
		If Status = 3
			Repeat
				Status = provide_miniz_decoder_input(Stream, 0, 0)
				Pending = harvest_miniz_output(Stream)
				
				CRC32 = mz_crc32( CRC32, Buffer, Pending )
				Destination.Write(Buffer, Pending)
			Until Status <> 3
		End If
		
		If Status = 0
		Else If Status = 1
			Local Unused:Int = number_miniz_unused_bytes(Stream)
			RecoverTail(Source + Size - Unused, Unused)
		Else
			Print "MiniZ error " + Status
		End If
		
		Return Size
	End Method
	
	Method RecoverTail(Source:Byte Ptr, Size:Long)
		If Tail.length < 8
			Local Arr:Byte[Size]
			MemCopy(Arr, Source, Size)
			Tail :+ Arr
		End If
		
		If Tail.length > 8
			RuntimeError "Extraneous data after gzip"
		End If
		
		If Tail.length = 8
			Local StoredCRC32:Int = 0
			Local SizeMod32:Int = 0
			
			MemCopy(Varptr StoredCRC32, Tail[0..4], 4)
			MemCopy(Varptr SizeMod32, Tail[4..8], 4)
			
			If (StoredCRC32 <> CRC32)
				RuntimeError "CRC32 mismatch"
			End If
		End If
	End Method
	
	Method Delete()
		free_miniz_stream(Stream)
	End Method
End Type
