Import BRL.Socket
Import BRL.SocketStream

Type ServeThreadParameters
	Field ClientSocket:TSocket
	Field ClientStream:TStream
	Field Timeout:Long
	Field PayloadTimeout:Long
	Field ThreadStartupMS:ULong
	Field ThreadLastActivityMS:ULong
	Field EncodingMode:String
	Field ThreadID:ULong
	Field BytesPerCycle:UInt
	Field EnableHostnameLookup:Int
	Field EnableCompression:Int
	Field CompressionSizeLimit:UInt
	Field EnableCaching:Int
	Field CachingLocation:String
	Field RequestPayloadLengthLimit:Int
	Field FilesizeAfterUpdateLimit:Long
	Field ConnectionFlags:String[]
	Field ExpectsContinue:Int
	Field KeepAliveAllowed:Int
	Field KeepAliveEnabled:Int
	Field WebDAVAllowed:Int
	Field UploadsAllowed:Int
	Field DeletesAllowed:Int
	Field MovesAllowed:Int
	Field RangesAllowed:Int
	Field EnableEncZNFS:Int
End Type

' This function will fetch the ServeThreadParameters of the caller thread
'
' It does affect performance because it leads to typecasting (2 times vs 0 times as before)
' But whatever, it's not a number cruncher, it's a web server that probably spends most of its time waiting for network anyway
Function GetParameters:ServeThreadParameters()
	Return ServeThreadParameters(CurrentThread()._data)
End Function
