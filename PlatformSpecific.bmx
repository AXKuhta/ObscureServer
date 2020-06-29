Import BRL.Socket
Import PUB.Zlib
Import BAH.Zstd
Import BRL.StandardIO
Import "Utils.bmx"

Extern
	?Not win32
		Function usleep:Int(usec:ULong)
	?

	?win32 Or ptr32
	Function crc32:ULong( crc:UInt,source:Byte Ptr,source_len:UInt )="unsigned long crc32(unsigned long, const void *, unsigned int)"
	?ptr64 And Not win32
	Function crc32:ULong( crc:ULong,source:Byte Ptr,source_len:ULong )="unsigned long crc32(unsigned long, const void *, unsigned int)"
	?
End Extern

?win32
	' Use our own """usleep""" if we are on Windows
	' Sadly on Windows busy-looping with Sleep(0) doesn't work too well, as it still causes
	' the CPU core load to jump to 100% and ramps the power consumption from 1W to 18W
	Function usleep:Int(uSec:ULong)
		If uSec < 1000
			Delay 1
		Else
			Delay Int(uSec / 1000)
		End If
	End Function
?

Function PrintClientIP(ClientSocket:TSocket, LookupHostname:Int = 0)
	LoggedPrint("IPv4: " + SocketRemoteIP(ClientSocket))
	
	If LookupHostname = 1
		LoggedPrint("Hostname: " + HostName(SocketRemoteIP(ClientSocket)))
	End If
End Function

Function GzipMemory:Int(CompressedMemory:Byte Ptr, CompressedSize:UInt Var, UncompressedMemory:Byte Ptr, Size:UInt)
	Local UncompressedCRC:ULong = 0
	Local CompressStatus:Int
	Local CompressedSize2:UInt = CompressedSize
	
	UncompressedCRC = crc32(0, UncompressedMemory, Size)
	
	' Note the CompressedMemory + 8, this is done to have 8 additional free bytes for gzip header to fit
	' We will also overwrite two bytes of zlib header that compress() adds
	CompressStatus = compress(CompressedMemory + 8, CompressedSize2, UncompressedMemory, Size)
	
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
	
	CompressedMemory[CompressedSize - 1] = (UncompressedCRC & $000000FF)
	CompressedMemory[CompressedSize - 2] = (UncompressedCRC & $0000FF00) Shr 8
	CompressedMemory[CompressedSize - 3] = (UncompressedCRC & $00FF0000) Shr 16
	CompressedMemory[CompressedSize - 4] = (UncompressedCRC & $FF000000) Shr 24
	
	Return CompressStatus
End Function

Function ZstdMemory:Size_T(CompressedMemory:Byte Ptr, CompressedSize:Size_T, UncompressedMemory:Byte Ptr, Size:Size_T)
        Return ZSTD_compress(CompressedMemory, CompressedSize, UncompressedMemory, Size, 14) ' 14 is the compression level
End Function
