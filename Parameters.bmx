Import BRL.Socket
Import BRL.SocketStream
Import "thread_local_storage.c"

Extern
	Function set_thread_parameters(parameters:ServeThreadParameters)
	Function get_thread_parameters:ServeThreadParameters()
End Extern

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
