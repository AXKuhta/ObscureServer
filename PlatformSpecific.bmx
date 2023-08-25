Import BRL.Socket
Import BAH.Zstd
Import BRL.StandardIO
Import "Utils.bmx"

Import "extras/interface_miniz.c"

Extern
	' OS
	Function sched_yield:Int()	
	
	' MiniZ
	Function mz_crc32:Int( crc:Int, addr:Byte Ptr, size:Size_T )
	Function alloc_miniz_encoder:Byte Ptr(dst:Byte Ptr, dst_len:Size_T)
	Function alloc_miniz_decoder:Byte Ptr(dst:Byte Ptr, dst_len:Size_T)
	Function free_miniz_stream(stream:Byte Ptr)
	Function provide_miniz_encoder_input:Int(stream:Byte Ptr, src:Byte Ptr, src_len:Size_T)
	Function provide_miniz_decoder_input:Int(stream:Byte Ptr, src:Byte Ptr, src_len:Size_T)
	Function finish_miniz_encoder_input:Int(stream:Byte Ptr)
	Function finish_miniz_decoder_input:Int(stream:Byte Ptr)
	Function harvest_miniz_output:Int(stream:Byte Ptr)
	Function number_miniz_unused_bytes:Int(stream:Byte Ptr)
End Extern

Function PrintClientIP(ClientSocket:TSocket, LookupHostname:Int = 0)
	LoggedPrint("IPv4: " + SocketRemoteIP(ClientSocket))
	
	If LookupHostname = 1
		LoggedPrint("Hostname: " + HostName(SocketRemoteIP(ClientSocket)))
	End If
End Function

Function GzipMemory:Int(Destination:Byte Ptr, CompressedSize:Size_T Var, Source:Byte Ptr, Size:Size_T)
	Local CompressedSize2:Size_T = CompressedSize - 14
	Local UncompressedCRC:Int = 0
	
	UncompressedCRC = mz_crc32(0, Source, Size)
	
	Local Stream:Byte Ptr = alloc_miniz_encoder(Destination + 10, CompressedSize2)
	Local Status:Int = provide_miniz_encoder_input(Stream, Source, Size)

	If Status
		LoggedPrint("MiniZ encode error: " + Status)
		free_miniz_stream(Stream)
		Return Status
	End If
	
	finish_miniz_encoder_input(Stream)
	CompressedSize2 = harvest_miniz_output(Stream)
	
	' Manually add gzip header
	' Hacky stuff
	Destination[0] = $1F ' + gzip magic
	Destination[1] = $8B ' / 
	
	Destination[2] = 8 ' This is the compression method. 8 is gzip's default
	Destination[3] = %00000001 ' This is the flag byte. Rightmost bit is "FTEXT"
	
	Destination[4] = 0 ' + These four bytes are supposed to be a timestamp, but we'll leave them empty
	Destination[5] = 0 ' |
	Destination[6] = 0 ' |
	Destination[7] = 0 ' /
	
	Destination[8] = 2 ' Extra flags. 2 means that slowest compression was used
	Destination[9] = 255 ' OS identificator. 255 means unknown
	
	' Add two 4-byte fields at the tail: original data CRC and original length
	' These are not essential, you can omit them -- but gzip will warn about early end of file
	' I also know that this will make cetrain proxies spill their memory -- right into the file you attempted to download!
	Local ModuloSize:UInt = Size Mod (2^32)
	
	MemCopy(Destination + 10 + CompressedSize2 + 0, Varptr UncompressedCRC, 4)
	MemCopy(Destination + 10 + CompressedSize2 + 4, Varptr ModuloSize, 4)

	CompressedSize = CompressedSize2 + 18
	
	free_miniz_stream(Stream)
	Return 0
End Function

' This function will taint the source memory!
Function UnGzipMemory:Int(Destination:Byte Ptr, Size:Size_T Var, Source:Byte Ptr, CompressedSize:Size_T)
	Local Status:Int
	Local Size2:Size_T = Size
	
	Local StoredCRC:Int = 0
	Local ActualCRC:Int = 0
	
	' The presence of a 10 byte header is required
	If CompressedSize < 10
		Print "UnGzipMemory: the data is too short to be a valid gzip"
		Return -1
	End If
	
	Local Stream:Byte Ptr = alloc_miniz_decoder(Destination, Size)

	Status = provide_miniz_decoder_input(Stream, Source + 10, CompressedSize - 18)
	
	If Status
		LoggedPrint("MiniZ decode error: " + Status)
		free_miniz_stream(Stream)
		Return Status
	End If
	
	finish_miniz_decoder_input(Stream)
	free_miniz_stream(Stream)
	
	If Size2 > 0
		ActualCRC = mz_crc32(0, Destination, UInt(Size2))
		StoredCRC = (Int Ptr (Source + CompressedSize - 8))[0]
				
		If StoredCRC <> ActualCRC
			Print "UnGzipMemory: CRC32 checksum didn't match"
			Print Hex(StoredCRC)
			Print Hex(ActualCRC)
			Status = -3
		End If
	End If
	
	Size = Size2
	
	Return Status
End Function

Function ZstdMemory:Size_T(CompressedMemory:Byte Ptr, CompressedSize:Size_T, UncompressedMemory:Byte Ptr, Size:Size_T)
	Return ZSTD_compress(CompressedMemory, CompressedSize, UncompressedMemory, Size, 14) ' 14 is the compression level
End Function

Function UnZstdMemory:Size_T(UncompressedMemory:Byte Ptr, Size:Size_T, CompressedMemory:Byte Ptr, CompressedSize:Size_T)
	Return ZSTD_decompress(UncompressedMemory, Size, CompressedMemory, CompressedSize)
End Function
