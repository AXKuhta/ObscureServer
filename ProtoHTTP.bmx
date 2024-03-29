Import BRL.Retro
Import "Parameters.bmx"
Import "DataLevel.bmx"
Import "DataLevelV2.bmx"

' This file contains functions and structures that are specific to HTTP protocol

Type HTTPRequestStruct
	Field Action:String
	Field Target:String
	Field Version:String
	
	Field Destination:String
	Field RangeStart:Long = 0
	Field RangeStop:Long = 0
	Field PayloadSize:Size_T = 0
End Type

Function GetRequestHeaderValue:String(Request:String[], Target:String)
	Local TargetLen:Int = Len(Target)
	Local i:Int
	
	For Local ii=0 To (Request.length - 1)
		If Left(Request[i], TargetLen) = Target
			i = ii
			Exit
		End If
	Next
	
	Return Right(Request[i], Len(Request[i]) - TargetLen)
End Function

Function WriteHeaders(Parameters:ServeThreadParameters)
	If Parameters.KeepAliveEnabled = 1
		WriteLine(Parameters.ClientStream, "Connection: Keep-Alive")
		WriteLine(Parameters.ClientStream, "Keep-Alive: timeout=" + Int(Parameters.Timeout / 1000))
	End If
	
	If Parameters.RangesAllowed = 1 Then WriteLine(Parameters.ClientStream, "Accept-Ranges: bytes")
	If Parameters.RequestPayloadCompressionAllowed = 1 Then WriteLine(Parameters.ClientStream, "Accept-Encoding: gzip, zstd")
End Function

Function ParseRequest:HTTPRequestStruct(Request:String)
	If Len(Request) = 0 Then Return Null
	If Len(Request) > 4096 Then Return Null

	Local ReturnStruct:HTTPRequestStruct = New HTTPRequestStruct
	Local RequestSplit:String[] = Request.Split(" ")
	
	' HTTP request must have three space separated parts
	' If it doesn't, abort
	If (RequestSplit.length <> 3) Then Return Null
	
	ReturnStruct.Action 	= RequestSplit[0].ToUpper()
	ReturnStruct.Target 	= RequestSplit[1]
	ReturnStruct.Version 	= RequestSplit[2].ToUpper()
	
	' If the protocol is not HTTP, also fail
	If Not ReturnStruct.Version.StartsWith("HTTP") Then Return Null
	
	Return ReturnStruct
End Function

Function ParseDestination:String(Destination:String)
	' Remove the protocol first
	If Destination.StartsWith("http://")
		Destination = Mid(Destination, 8)
	End If
	
	' Then get rid of the domain
	Destination = Mid(Destination, Destination.Find("/") + 2)
	
	' Run URLDecode on the shortened string
	Destination = URLDecode(Destination)
	
	Return Destination
End Function

Function ExtractHeaderFlags:String[](HeaderString:String)
	Local ParameterStart:Int = HeaderString.Find(":") + 2
	' TODO: Error handling here
		
	HeaderString = Mid(HeaderString, ParameterStart).ToLower().Replace(" ", "")
	' Cut the header name -> convert all to lowercase -> remove all spaces
	
	Return HeaderString.Split(",")
End Function

Function ExtractRanges:Long[](RangesLine:String)
	Local ReturnStruct:Long[2]
	
	Local FirstStart:Int = RangesLine.Find("=") + 2 
	Local SecondStart:Int = RangesLine.Find("-") + 2
		
	ReturnStruct[0] = Long(Mid(RangesLine, FirstStart, (SecondStart - FirstStart)))
	ReturnStruct[1] = Long(Mid(RangesLine, SecondStart))
	
	Return ReturnStruct
End Function

Function ProcessHTTPRequest(ParsedRequest:HTTPRequestStruct, Parameters:ServeThreadParameters)
	
	If ParsedRequest.Target = "/" 
		ParsedRequest.Target = "index.html"
	Else
		' Cut the leading slash
		ParsedRequest.Target = Right(ParsedRequest.Target, Len(ParsedRequest.Target) - 1)
		
		' Check if request is explicitly pointing at a subdirectory
		If Right(ParsedRequest.Target, 1) = "/" Then ParsedRequest.Target :+ "index.html"
	End If
		
	If Instr(ParsedRequest.Target, "?")
		LoggedPrint("WARNING: Request queries (link?key=value) are not supported. Cutting the query out.")
		LoggedPrint("TODO: Handle queries in a better way.")
		ParsedRequest.Target = Left(ParsedRequest.Target, ParsedRequest.Target.Find("?"))
	End If
	
	LoggedPrint("Request: " + ParsedRequest.Action + " " + ParsedRequest.Target + " " + ParsedRequest.Version)
	
	If ParsedRequest.Action = "GET"
		ProcessDownloadRequest(ParsedRequest, Parameters)
	
	ElseIf (ParsedRequest.Action = "POST") Or (ParsedRequest.Action = "PUT")
		ProcessUploadRequest(ParsedRequest, Parameters)
		
	ElseIf ParsedRequest.Action = "DELETE"
		ProcessDeleteRequest(ParsedRequest, Parameters)
		
	ElseIf ParsedRequest.Action = "MOVE"
		ProcessMoveRequest(ParsedRequest, Parameters)
		
	ElseIf ParsedRequest.Action = "HEAD"
		ProcessHEADRequest(ParsedRequest, Parameters)
			
	ElseIf ParsedRequest.Action = "OPTIONS"
		SendSuccess(200, Parameters, "", 1)
							
	End If

End Function

Function ProcessDownloadRequest(ParsedRequest:HTTPRequestStruct, Parameters:ServeThreadParameters)
	Local ClientStream:TStream = Parameters.ClientStream
	Local DownloadMode:Int
	
	' Check if the file exists first
	If FileType(ParsedRequest.Target) <> 1
		SendError(404, Parameters, "Error 404. File ["+ParsedRequest.Target+"] was not found.")
		Return
	End If
	
	DownloadMode = DecideDownloadMode(ParsedRequest, Parameters)
	
	If RunAbilityCheck(Parameters) = 0 Then Return
	
	Select DownloadMode
		Case 1 ' Uncompressed
			WriteLine(ClientStream, "HTTP/1.1 200 OK")
			WriteHeaders(Parameters)
			SendFile(ParsedRequest.Target, Parameters)
			
		Case 2 ' Compressed
			WriteLine(ClientStream, "HTTP/1.1 200 OK")
			WriteHeaders(Parameters)
			SendCompressedFile(ParsedRequest.Target, Parameters)
		
		Case 3 ' Slice
			WriteLine(ClientStream, "HTTP/1.1 206 Partial Content")
			WriteHeaders(Parameters)
			SendFileSlice(ParsedRequest.Target, ParsedRequest.RangeStart, ParsedRequest.RangeStop, Parameters)

		Case 4 ' Compressed slice
			WriteLine(ClientStream, "HTTP/1.1 206 Partial Content")
			WriteHeaders(Parameters)
			SendCompressedFileSlice(ParsedRequest.Target, ParsedRequest.RangeStart, ParsedRequest.RangeStop, Parameters)
						
			
		Default
			SendError(500, Parameters)
			LoggedPrint("(An error occured)")
			Return
	End Select
	
End Function

Function ProcessUploadRequest(ParsedRequest:HTTPRequestStruct, Parameters:ServeThreadParameters)
	Local ResponseCode:Int 
	Local TargetSize:Long
	Local TargetType:Int = FileType(ParsedRequest.Target)
	Local TargetDir:String = ExtractDir(ParsedRequest.Target)
	Local Result:Size_T
	Local File:TStream

	LoggedPrint("Incoming file. Name: "+ParsedRequest.Target)
	
	If Not Parameters.UploadsAllowed
		LoggedPrint("Got a file upload, but that's not allowed. No changes to filesystem made.")
		SendError(405, Parameters)
		Return
	End If
	
	If TargetDir <> ""
		' If there's a targer dir...
		' ...check that it exists and is not a file 
		If FileType(TargetDir) <> 2
			LoggedPrint("Got an attempt to upload a file into a non-existing directory ["+TargetDir+"]")
			SendError(404, Parameters, "Directory ["+TargetDir+"] doesn't exist.")
			Return
		End If
	End If
	
	If TargetType = 1
		TargetSize = FileSize(ParsedRequest.Target)
	ElseIf TargetType = 2
		LoggedPrint("["+ParsedRequest.Target+"] Is a directory!")
		SendError(406, Parameters, "Target is a directory! You can't do *that*!")
		Return
	End If
	
	' With PUT requests we must overwrite the file
	' If it's a POST and the file does exist, we must update it
	' And if this is a POST and the file doesn't exist yet, we must create it
	If (ParsedRequest.Action = "PUT") Or (TargetType = 0)		
		LoggedPrint("Creating ["+ParsedRequest.Target+"]")
		
		File = WriteFile(ParsedRequest.Target)
		
		If Not File
			LoggedPrint("Failed to create ["+ParsedRequest.Target+"]!")
			SendError(500, Parameters, "Failed to create the file.")
			Return
		End If

		ResponseCode = 204
	Else
		If (TargetSize + ParsedRequest.PayloadSize) > Parameters.FilesizeAfterUpdateLimit ' If this POST request would bring the target file size over the limit, refuse to do it
			LoggedPrint("This POST would bring the file size over the limit!")
			SendError(406, Parameters, "File is too large.")
			Return
		End If
		
		LoggedPrint("Updating ["+ParsedRequest.Target+"]")
		
		File = OpenFile(ParsedRequest.Target)
		
		If Not File
			LoggedPrint("Failed to open ["+ParsedRequest.Target+"]!")
			SendError(500, Parameters, "Failed to open the file.")
			Return
		End If
		
		SeekStream(File, TargetSize)
		
		ResponseCode = 200
	End If
	
	' Should really go into ParsedRequest; Parameters should not change at runtime
	If Parameters.RequestPayloadEncodingMode = "gzip"
		Result = SocketReceive(New MiniZDecodeAdapter(File), TSocketStream(Parameters.ClientStream), ParsedRequest.PayloadSize)
	Else
		Result = SocketReceive(File, TSocketStream(Parameters.ClientStream), ParsedRequest.PayloadSize)
	End If
	
	CloseFile(File)
	
	If Result = ParsedRequest.PayloadSize
		LoggedPrint("Upload complete")
		SendSuccess(ResponseCode, Parameters)
	Else
		LoggedPrint("Incomplete upload! " + Result/1024 + "KB from " + ParsedRequest.PayloadSize/1024 + "KB")
	End If
End Function

Function ProcessDeleteRequest(ParsedRequest:HTTPRequestStruct, Parameters:ServeThreadParameters)
	Local ClientStream:TStream = Parameters.ClientStream
	Local Status:Int
	
	If Parameters.DeletesAllowed = 0
		SendError(405, Parameters)
		Return
	End If
	
	If FileType(ParsedRequest.Target) <> 1
		SendError(404, Parameters, "Error 404 on deletion. File ["+ParsedRequest.Target+"] was not found.")
		Return
	End If
	
	Status = DeleteFile(ParsedRequest.Target)
	
	If Status
		SendSuccess(200, Parameters)
	Else
		SendError(500, Parameters, "Failed to delete ["+ParsedRequest.Target+"]")
	End If
End Function

Function ProcessMoveRequest(ParsedRequest:HTTPRequestStruct, Parameters:ServeThreadParameters)
	Local StatusCopy:Int
	Local StatusDelete:Int
	
	If Parameters.MovesAllowed = 0
		SendError(405, Parameters)
		Return
	End If
	
	If ParsedRequest.Target = ParsedRequest.Destination
		SendError(403, Parameters)
		Return
	End If
	
	Select FileType(ParsedRequest.Target)
		Case 0
			SendError(404, Parameters)
			Return
			
		Case 1
			StatusCopy = CopyFile(ParsedRequest.Target, ParsedRequest.Destination)
			If StatusCopy
				StatusDelete = DeleteFile(ParsedRequest.Target)
			End If
			
		Case 2
			StatusCopy = CopyDir(ParsedRequest.Target, ParsedRequest.Destination)
			If StatusCopy
				StatusDelete = DeleteDir(ParsedRequest.Target)
			End If
		
	End Select
	
	If (StatusCopy = 0) Or (StatusDelete = 0)
		LoggedPrint("Failed to move ["+ParsedRequest.Target+"] -> ["+ParsedRequest.Destination+"]!")
		SendError(500, Parameters, "Failed to move ["+ParsedRequest.Target+"] -> ["+ParsedRequest.Destination+"]")
	End If

	SendSuccess(200, Parameters)
End Function

Function ProcessHEADRequest(ParsedRequest:HTTPRequestStruct, Parameters:ServeThreadParameters)
	Local ClientStream:TStream = Parameters.ClientStream
	Local FilenameCached:String
	Local DownloadMode:Int
	Local RangeSize:Long
	Local Size:Long
	
	' First of all, we should check whether the target exists
	If FileType(ParsedRequest.Target) <> 1
		' That's a HEAD, so no text payload is allowed on error
		SendError(404, Parameters)
		Return
	End If
	
	' If the file exists, get the size
	Size = FileSize(ParsedRequest.Target)
	
	' If this is a ranged request, recalculate the size and properly fill the stop value
	If (ParsedRequest.RangeStart Or ParsedRequest.RangeStop)
		If ParsedRequest.RangeStop = 0
			ParsedRequest.RangeStop = Size
			RangeSize = ParsedRequest.RangeStop - ParsedRequest.RangeStart
		Else
			RangeSize = ParsedRequest.RangeStop - ParsedRequest.RangeStart + 1
		End If
	End If
		
	' Then decide whether it will be compressed or not
	DownloadMode = DecideDownloadMode(ParsedRequest, Parameters)
	' And (after a check) start giving the data back
	If RunAbilityCheck(Parameters) = 0 Then Return
	
	Select DownloadMode
		Case 1 ' Uncompressed and not a slice
			WriteLine(ClientStream, "HTTP/1.1 200 OK")
			WriteLine(ClientStream, "Content-Length: " + Size)
			
		Case 2 ' Compressed and not a slice
			WriteLine(ClientStream, "HTTP/1.1 200 OK")
			WriteLine(ClientStream, "Content-Encoding: " + Parameters.EncodingMode)
			
			' Try to stat the compression cache file, that may yield the size
			If Parameters.EnableCaching = 1
				FilenameCached = Parameters.CachingLocation + ParsedRequest.Target + "." + Parameters.EncodingMode + "c"
			
				If FileType(FilenameCached)
					' If the compressed file was cached, check whether the cache is outdated
					' If it isn't outdated, we can provide the correct size
					' If it is outdated, we won't send the Content-Length
					If FileTime(ParsedRequest.Target) < FileTime(FilenameCached)
						WriteLine(ClientStream, "Content-Length: " + FileSize(FilenameCached))
					End If
				Else
					' And if the file wasn't cached, we won't send the Content-Length
				End If
			End If
						
		Case 3 ' Uncompressed slice
			WriteLine(ClientStream, "HTTP/1.1 206 Partial Content")
			WriteLine(ClientStream, "Content-Range: bytes " + ParsedRequest.RangeStart + "-" + ParsedRequest.RangeStop + "/" + Size)
			WriteLine(ClientStream, "Content-Length: " + RangeSize)
			
		Case 4 ' Compressed slice
			WriteLine(ClientStream, "HTTP/1.1 206 Partial Content")
			WriteLine(ClientStream, "Content-Range: bytes " + ParsedRequest.RangeStart + "-" + ParsedRequest.RangeStop + "/" + Size)
			
		Default
			' In case of an error, DecideDownloadMode() had already sent an error, so just return
			Return 
	End Select
		
	WriteHeaders(Parameters)
	WriteLine(ClientStream, "")
End Function

' This function decides what mode should be used for a download:
' 1 - Uncompressed transfer
' 2 - Compressed transfer
' 3 - Uncompressed slice
' 4 - Compressed slice
'
' 0 - Error
Function DecideDownloadMode(ParsedRequest:HTTPRequestStruct, Parameters:ServeThreadParameters)
	Local Size:Long = FileSize(ParsedRequest.Target)
	
	Local Compressable:Int = (Parameters.EnableCompression = 1) And (Size < Parameters.CompressionSizeLimit) And (Parameters.EncodingMode <> "")
	Local Ranged:Int = (ParsedRequest.RangeStart Or ParsedRequest.RangeStop)
	
	If (Parameters.RangesAllowed = 0) And Ranged
		LoggedPrint("Got a ranged request but ranges are disabled.")
		SendError(416, Parameters)
		Return 0
	End If
	
	If ParsedRequest.RangeStart > Size
		LoggedPrint("Request has a malformed range (Start > Size).")
		SendError(416, Parameters)
		Return 0
	End If
		
	If Ranged
		If Compressable
			Return 4
		Else
			Return 3
		End If
	End If
		
	If Compressable
		Return 2
	End If
	
	Return 1
End Function

' Returns an [Allow: AAA, BBB, ...] header string
Function GetAllowedMethods:String(Parameters:ServeThreadParameters)
	Local AllowedMethods:String
	
	AllowedMethods = "Allow: OPTIONS, GET, HEAD"
	If Parameters.UploadsAllowed Then AllowedMethods :+ ", POST, PUT"
	If Parameters.DeletesAllowed Then AllowedMethods :+ ", DELETE"
	If Parameters.MovesAllowed Then AllowedMethods :+ ", MOVE"
	If Parameters.WebDAVAllowed Then AllowedMethods :+ ", PROPFIND, PROPPATCH"

	Return AllowedMethods
End Function

' This function will send a status, like 100 Continue
' The clien't shouldn't disconnect after that
Function SendStatus(StatusCode:Int, Parameters:ServeThreadParameters)
	Local StatusText:String
	
	Select StatusCode
		Case 100
			StatusText = "Continue"
	
		Default
			StatusText = ""
	End Select
	
	If RunAbilityCheck(Parameters) = 0 Then Return
	WriteLine(Parameters.ClientStream, "HTTP/1.1 " + StatusCode + " " + StatusText)
	WriteLine(Parameters.ClientStream, "")
End Function

' In a scope of a single request this function will send a final error
' The client usually disconnects after that
Function SendError(ErrorCode:Int, Parameters:ServeThreadParameters, ErrorText:String = "")
	LoggedPrint(ErrorCode + "'d.")
	
	Local StatusText:String
	
	Select ErrorCode
		Case 404
			StatusText = "Not Found"
		Case 405
			StatusText = "Method Not Allowed"
		Case 406
			StatusText = "Not acceptable"
		Case 413
			StatusText = "Payload Too Large"
		Case 416
			StatusText = "Range Not Satisfiable"
		Case 500
			StatusText = "Internal Server Error"
			
		Default
			StatusText = ""				
	End Select
	
	If RunAbilityCheck(Parameters) = 0 Then Return
	WriteLine(Parameters.ClientStream, "HTTP/1.1 " + ErrorCode + " " + StatusText)
	If ErrorCode = 405 Then WriteLine(Parameters.ClientStream, GetAllowedMethods(Parameters)) ' Spec says we must do that on 405s
	WriteHeaders(Parameters)
	
	If ErrorText <> ""
		' If the user specified a text payload to go along with the error, send it
		SendText(ErrorText, Parameters)
	Else
		' Otherwise, signal the end of line
		WriteLine(Parameters.ClientStream, "Content-Length: 0")
		WriteLine(Parameters.ClientStream, "")
	End If
End Function

' In a scope of a single request this function will send a final OK status
' If the connection is keep-alive, the client shouldn't disconnect after that and could send another request
Function SendSuccess(SuccessCode:Int, Parameters:ServeThreadParameters, AdditionalText:String = "", OptionsResponse:Int = 0)
	Local StatusText:String
	
	Select SuccessCode
		Case 200
			StatusText = "OK"
		Case 204
			StatusText = "Created"
		
		Default
			StatusText = ""
	End Select
	
	If RunAbilityCheck(Parameters) = 0 Then Return
	WriteLine(Parameters.ClientStream, "HTTP/1.1 " + SuccessCode + " " + StatusText)
	
	' This is a hacky special case for when this function is used to reply to OPTIONS
	If OptionsResponse
		WriteLine(Parameters.ClientStream, GetAllowedMethods(Parameters))
		If Parameters.WebDAVAllowed = 1
			WriteLine(Parameters.ClientStream, "DAV: 1")
		End If
	End If
	
	WriteHeaders(Parameters)
	
	If AdditionalText <> ""
		SendText(AdditionalText, Parameters)
	Else
		WriteLine(Parameters.ClientStream, "Content-Length: 0")
		WriteLine(Parameters.ClientStream, "")
	End If
End Function

