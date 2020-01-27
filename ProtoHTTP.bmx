Import BRL.Retro
Import "Parameters.bmx"
Import "DataLevel.bmx"

' This file contains functions and structures that are specific to HTTP protocol

Type HTTPRequestStruct
	Field Action:String
	Field Target:String
	Field Version:String
	
	Field Destination:String
	Field RangeStart:Long = 0
	Field RangeStop:Long = 0
	Field Payload:Byte Ptr
	Field PayloadLength:Long
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
End Function

Function ParseRequest:HTTPRequestStruct(Request:String)
	If Len(Request) = 0 Then Return Null
	If Len(Request) > 4096 Then Return Null

	Local ReturnStruct:HTTPRequestStruct = New HTTPRequestStruct
	Local RequestSplit:String[] = Request.Split(" ")
	
	' HTTP request must have three space separated parts
	' If it doesn't, abort
	If (RequestSplit.length <> 3) Then Return Null
	
	ReturnStruct.Action = RequestSplit[0]
	ReturnStruct.Target = RequestSplit[1]
	ReturnStruct.Version = RequestSplit[2]
	
	' If the protocol is not HTTP, also fail
	If Not Lower(ReturnStruct.Version).StartsWith("http") Then Return Null
	
	Return ReturnStruct
End Function

Function ParseDestination:String(Destination:String)
	' Remove the protocol first
	If Destination.StartsWith("http://")
		Destination = Mid(Destination, 8)
	End If
	
	' Then get rid of the domain
	Destination = Mid(Destination, Destination.Find("/") + 2)
	
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
		LoggedPrint("WARNING: Request queries (link?key=value) are not supported. Cutting the query out.", Parameters.ThreadID)
		LoggedPrint("TODO: Handle queries in a better way.", Parameters.ThreadID)
		ParsedRequest.Target = Left(ParsedRequest.Target, ParsedRequest.Target.Find("?"))
	End If
	
	LoggedPrint("Request: " + ParsedRequest.Action + " " + ParsedRequest.Target + " " + ParsedRequest.Version, Parameters.ThreadID)
	
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
		SendSuccess(Parameters, 200, "", 1)
							
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
			LoggedPrint("(An error occured)", Parameters.ThreadID)
			Return
	End Select
	
End Function

Function ProcessUploadRequest(ParsedRequest:HTTPRequestStruct, Parameters:ServeThreadParameters)
	Local ResponseCode:Int 
	Local TargetSize:Long
	Local TargetType:Int = FileType(ParsedRequest.Target)
	Local TargetDir:String = ExtractDir(ParsedRequest.Target)
	Local Status:Int

	LoggedPrint("Incoming file. Name: "+ParsedRequest.Target+"; Size: "+(ParsedRequest.PayloadLength / 1024)+"KB.", Parameters.ThreadID)
	
	If Not Parameters.UploadsAllowed
		LoggedPrint("Got a file upload, but that's not allowed. No changes to filesystem made.", Parameters.ThreadID)
		SendError(405, Parameters)
		Return
	End If
	
	If TargetDir <> ""
		' If there's a targer dir...
		' ...check that it exists and is not a file 
		If FileType(TargetDir) <> 2
			LoggedPrint("Got an attempt to upload a file into a non-existing directory ["+TargetDir+"]", Parameters.ThreadID)
			SendError(404, Parameters, "Directory ["+TargetDir+"] doesn't exist.")
			Return
		End If
	End If
	
	If TargetType = 1
		TargetSize = FileSize(ParsedRequest.Target)
	ElseIf TargetType = 2
		LoggedPrint("["+ParsedRequest.Target+"] Is a directory!", Parameters.ThreadID)
		SendError(406, Parameters, "Target is a directory! You can't do *that*!")
		Return
	End If
	
	
	If (ParsedRequest.Action = "PUT") Or (TargetType = 0)
		' With PUT requests we must overwrite the file
		' And if this is a POST and the file doesn't exist yet, we must create it
		ResponseCode = 204
		
		LoggedPrint("Creating ["+ParsedRequest.Target+"]", Parameters.ThreadID)
		Status = ReceiveFile(ParsedRequest.Target, ParsedRequest.Payload, ParsedRequest.PayloadLength)
	Else
		' If it's a POST and the file does exist, we must update it
		ResponseCode = 200
		
		If (TargetSize + ParsedRequest.PayloadLength) > Parameters.FilesizeAfterUpdateLimit
			' If this POST request would bring the target file size over the limit, refuse to do it
			LoggedPrint("This POST would bring the file size over the limit!", Parameters.ThreadID)
			SendError(406, Parameters, "File is too large.")
			Return
		End If
		
		LoggedPrint("Updating ["+ParsedRequest.Target+"]", Parameters.ThreadID)
		Status = UpdateFile(ParsedRequest.Target, ParsedRequest.Payload, ParsedRequest.PayloadLength)
	End If
	
	If Status <> 0
		SendSuccess(Parameters, ResponseCode)
	Else
		LoggedPrint("Failed to create or update ["+ParsedRequest.Target+"]!", Parameters.ThreadID)
		SendError(500, Parameters, "Failed to create or update the file.")
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
		SendSuccess(Parameters)
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
			StatusDelete = DeleteFile(ParsedRequest.Target)
			
		Case 2
			StatusCopy = CopyDir(ParsedRequest.Target, ParsedRequest.Destination)
			StatusDelete = DeleteDir(ParsedRequest.Target)
		
	End Select
	
	If (StatusCopy = 0) Or (StatusDelete = 0)
		SendError(500, Parameters, "Failed to move ["+ParsedRequest.Target+"]")
	End If

	SendSuccess(Parameters)
End Function

Function ProcessHEADRequest(ParsedRequest:HTTPRequestStruct, Parameters:ServeThreadParameters)
	Local ClientStream:TStream = Parameters.ClientStream
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
			WriteLine(ClientStream, "Content-Encoding: gzip")
			' Try to stat the compression cache file, that may yield the size
			If Parameters.EnableCaching = 1
				If FileTime(ParsedRequest.Target) < FileTime(Parameters.CachingLocation + ParsedRequest.Target + ".gzc")
					WriteLine(ClientStream, "Content-Length: " + FileSize(Parameters.CachingLocation + ParsedRequest.Target + ".gzc"))
				Else
					' We do that when the cache is outdated
					WriteLine(ClientStream, "Content-Length: 0")
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
		LoggedPrint("Got a ranged request but ranges are disabled.", Parameters.ThreadID)
		SendError(416, Parameters)
		Return 0
	End If
	
	If ParsedRequest.RangeStart > Size
		LoggedPrint("Request has a malformed range (Start > Size).", Parameters.ThreadID)
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
	LoggedPrint(ErrorCode + "'d.", Parameters.ThreadID)
	
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
Function SendSuccess(Parameters:ServeThreadParameters, SuccessCode:Int = 200, AdditionalText:String = "", OptionsResponse:Int = 0)
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

