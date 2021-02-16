Import BRL.Socket
Import PUB.Zlib
Import BAH.Zstd
Import BRL.StandardIO
Import "Utils.bmx"

Extern
	Function sched_yield:Int()

	?win32 Or ptr32
	Function crc32:ULong( crc:UInt,source:Byte Ptr,source_len:UInt )="unsigned long crc32(unsigned long, const void *, unsigned int)"
	?ptr64 And Not win32
	Function crc32:ULong( crc:ULong,source:Byte Ptr,source_len:ULong )="unsigned long crc32(unsigned long, const void *, unsigned int)"
	?
End Extern

Function PrintClientIP(ClientSocket:TSocket, LookupHostname:Int = 0)
	LoggedPrint("IPv4: " + SocketRemoteIP(ClientSocket))
	
	If LookupHostname = 1
		LoggedPrint("Hostname: " + HostName(SocketRemoteIP(ClientSocket)))
	End If
End Function

Function GzipMemory:Int(CompressedMemory:Byte Ptr, CompressedSize:Size_T Var, UncompressedMemory:Byte Ptr, Size:Size_T)
	Local UncompressedCRC:Int = 0
	Local Status:Int
	?ptr64 And raspberrypi
	Local CompressedSize2:ULong = CompressedSize
	?Not raspberrypi
	Local CompressedSize2:UInt = CompressedSize
	?
		
	UncompressedCRC = crc32(0, UncompressedMemory, UInt(Size))
	
	' Note the CompressedMemory + 8, this is done to have 8 additional free bytes for gzip header to fit
	' We will also overwrite two bytes of zlib header that compress() adds
	Status = compress(CompressedMemory + 8, CompressedSize2, UncompressedMemory, UInt(Size))
	
	CompressedSize = CompressedSize2 + 8
	
	' Hacky stuff. Manually add gzip header and replace adler32 tail with crc32 tail
	CompressedMemory[0] = $1F ' + gzip magic
	CompressedMemory[1] = $8B ' / 
	
	CompressedMemory[2] = 8 ' This is the compression method. 8 is gzip's default
	CompressedMemory[3] = %00000001 ' This is the flag byte. Rightmost bit is "FTEXT"
	
	CompressedMemory[4] = 0 ' + These four bytes are supposed to be a timestamp, but we'll leave them empty
	CompressedMemory[5] = 0 ' |
	CompressedMemory[6] = 0 ' |
	CompressedMemory[7] = 0 ' /
	
	CompressedMemory[8] = 2 ' Extra flags. 2 means that slowest compression was used
	CompressedMemory[9] = 255 ' OS identificator. 255 means unknown
	
	' Add two 4-byte fields at the tail: original data CRC and original length
	' These are not essential, you can omit them -- but gzip will warn about early end of file
	' I also know that this will make cetrain proxies spill their memory -- right into the file you attempted to download!
	Local Tail:Int Ptr = Int Ptr (CompressedMemory + CompressedSize - 4)
	Tail[0] = UncompressedCRC
	Tail[1] = Size
	
	' What a mess
	CompressedSize :+ 4
	
	Return Status
End Function

' This function will taint the source memory!
Function UnGzipMemory:Int(UncompressedMemory:Byte Ptr, Size:Size_T Var, CompressedMemory:Byte Ptr, CompressedSize:Size_T)
	Local Status:Int
	?ptr64 And raspberrypi
	Local Size2:ULong = Size
	?Not raspberrypi
	Local Size2:UInt = Size
	?
	
	Local StoredCRC:Int = 0
	Local ActualCRC:Int = 0
	
	' The presence of a 10 byte header is required
	If CompressedSize < 10
		Print "UnGzipMemory: the data is too short to be a valid gzip"
		Return -1
	End If
	
	' Manually add a zlib-compatible header
	CompressedMemory[8] = $78 ' + DEFLATE algorithm
	CompressedMemory[9] = $DA ' + Slowest compression

	' We can't really replace the crc32 checksum with an adler32 checksum for the data that we didn't yet decompress
	' Status will always return -3 (Z_DATA_ERROR) as a result
	' You just kinda have to assume data was not actually corrupted
	Status = uncompress(UncompressedMemory, Size2, CompressedMemory + 8, UInt(CompressedSize) - 8)
	
	If Status = -3 Then Status = 0
	
	' But you know what we can do? We can validate the crc32 checksum ourselves!
	If Size2 > 0
		ActualCRC = crc32(0, UncompressedMemory, UInt(Size2))
		
		StoredCRC = (Int Ptr (CompressedMemory + CompressedSize - 8))[0]
				
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
