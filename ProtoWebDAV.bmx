Import Text.XML
Import "Utils.bmx"
Import "Parameters.bmx"
Import "DataLevel.bmx"
Import "ProtoHTTP.bmx"

' This file contains functions are structures specific to WebDAV
' WebDAV is built on top of HTTP, so we include the ProtoHTTP
'
' P.S.: Some WebDAV clients don't like it when, after a 404 error, server also gives a text payload detailing the error
' Missing favicon.ico could trigger that

Function ProcessWebDAVRequest(ParsedRequest:HTTPRequestStruct, Parameters:ServeThreadParameters)
	Local RequestString:String
	Local ResponseString:String
	Local TargetPath:String 
	
	LoggedPrint("WebDAV request.")
	
	If Not Parameters.WebDAVAllowed
		LoggedPrint("But WebDAV is disabled. Responding with 405.")
		SendError(405, Parameters)
		Return
	End If
	
	If ParsedRequest.Payload
		RequestString = String.FromBytes(ParsedRequest.Payload.Pointer, Int(ParsedRequest.Payload.Size))
		
		Local XMLTree:TxmlDoc = TxmlDoc.readDoc(RequestString)
		
		' TODO: Handle the creation of collections (i.e. folders)
		' LoggedPrint("Client XML: " + XMLTree.ToStringFormat(True))
	Else
		LoggedPrint("Client didn't send any XML payload for PROPFIND!")
	End If
	
	
	' First of all we should stat the target file/dir to decide whether we should reply with 207 Or 404
	
	' Start off by making a valid FS path
	If ParsedRequest.Target = "/"
		TargetPath = "."
	ElseIf Right(ParsedRequest.Target, 1) = "/"
		' Target is a directory and we need to trim the trailing slash
		TargetPath = "." + Left(ParsedRequest.Target, Len(ParsedRequest.Target) - 1)
	Else
		' Target is a file, so we only need to add the dot in front
		TargetPath = "." + ParsedRequest.Target
	End If
	
		
	Select FileType(TargetPath)
		Case 0 ' Does not exist or no permission to read or corrupted on disk
			LoggedPrint("404'd during a WebDAV request: " + TargetPath + " not found.")
			SendError(404, Parameters, "Error 404. File ["+ TargetPath +"] was not found.")		
			Return

		Case 1 ' This is a file. Build a stat for it.
			ResponseString = BuildXMLFileStat(TargetPath)
			
		Case 2 ' This is a directory. Build a listing for it.
			ResponseString = BuildXMLDirectoryListing(TargetPath)
			
	End Select
		
	If RunAbilityCheck(Parameters) = 0 Then Return
	WriteLine(Parameters.ClientStream, "HTTP/1.1 207 Multi-status")
	WriteLine(Parameters.ClientStream, "Content-type: text/xml; charset=~qutf-8~q")
	WriteHeaders(Parameters)
	SendText(ResponseString, Parameters)
End Function


Function BuildXMLDirectoryListing:String(DirectoryPath:String)
	Local DirectoryFiles:Byte Ptr
		
	Local XMLTree:TxmlDoc = TxmlDoc.newDoc("1.0") ' Create a new XML1.0
	Local RootNode:TxmlNode = TxmlNode.newNode("D:multistatus")
	XMLTree.setRootElement(RootNode)
	RootNode.addAttribute("xmlns:D", "DAV:")
	
	Local ResponseNode:TxmlNode
	Local PropstatNode:TxmlNode
	Local PropNode:TxmlNode
	
	' A special entry for currently opened folder
	ResponseNode = RootNode.addChild("D:response")
	If DirectoryPath = "."
		ResponseNode.addChild("D:href", "/") ' Href is at root
	Else
		ResponseNode.addChild("D:href", Mid(DirectoryPath, 2) + "/") ' Href is within a subfolder
	End If
	PropstatNode = ResponseNode.addChild("D:propstat")
	PropNode = PropstatNode.addChild("D:prop")
	PropNode.addChild("D:resourcetype").addChild("D:collection")
	PropNode.addChild("D:displayname", "") ' But the name is empty
	PropstatNode.AddChild("D:status", "HTTP/1.1 200 OK")
	
	
	DirectoryFiles = ReadDir(DirectoryPath)
	
	If Not DirectoryFiles Then Print "Couldn't read directory: " + DirectoryPath
	
	' Entry can be both a file or a folder
	Local ListEntryName:String
	Local ListEntrySize:String
	Local ListEntryTime:String
	Local EntryPath:String
	
	Repeat
		ListEntryName = NextFile(DirectoryFiles)
		If ListEntryName = ".." Then Continue
		If ListEntryName = "." Then Continue
		If ListEntryName = "" Then Exit
				
		EntryPath = DirectoryPath + "/" + ListEntryName
		
		ResponseNode = RootNode.addChild("D:response")
		ResponseNode.addChild("D:href", Right(EntryPath, Len(EntryPath) - 1)) ' Will trim the dot on the left
		
		PropstatNode = ResponseNode.addChild("D:propstat")
		PropNode = PropstatNode.addChild("D:prop")

		
		Select FileType(EntryPath)
			Case 0
				Print "WebDAV: Unable to stat file: " + EntryPath 
			Case 1
				PropNode.addChild("D:creationdate")
				PropNode.addChild("D:displayname", StripDir(EntryPath))
				PropNode.addChild("D:getcontentlength", FileSize(EntryPath))
				PropNode.addChild("D:getcontenttype")
				PropNode.addChild("D:getetag")
				PropNode.addChild("D:getlastmodified", GetHTTPTime(FileTime(EntryPath)))
				PropNode.addChild("D:resourcetype")
				PropNode.addChild("D:supportedlock")
			Case 2
				PropNode.addChild("D:creationdate")
				PropNode.addChild("D:displayname", StripDir(EntryPath))
				PropNode.addChild("D:resourcetype").addChild("D:collection")
				PropNode.addChild("D:supportedlock")
		End Select
		
		PropstatNode.AddChild("D:status", "HTTP/1.1 200 OK")
	Forever
	
	'Print "Directory listing: " + XMLTree.ToStringFormat(True)
	Return XMLTree.ToString()
End Function

Function BuildXMLFileStat:String(FilePath:String)
	Local XMLTree:TxmlDoc = TxmlDoc.newDoc("1.0")
	Local RootNode:TxmlNode = TxmlNode.newNode("D:multistatus")
	XMLTree.setRootElement(RootNode)
	RootNode.addAttribute("xmlns:D", "DAV:")
	
	Local ResponseNode:TxmlNode
	Local PropstatNode:TxmlNode
	Local PropNode:TxmlNode
	
	ResponseNode = RootNode.addChild("D:response")
	ResponseNode.addChild("D:href", "/" + FilePath)
	PropstatNode = ResponseNode.addChild("D:propstat")
	PropNode = PropstatNode.addChild("D:prop")
	PropNode.addChild("D:creationdate")
	PropNode.addChild("D:displayname", StripDir(FilePath))
	PropNode.addChild("D:getcontentlength", FileSize(FilePath))
	PropNode.addChild("D:getcontenttype")
	PropNode.addChild("D:getetag")
	PropNode.addChild("D:getlastmodified", GetHTTPTime(FileTime(FilePath)))
	PropNode.addChild("D:resourcetype")
	PropNode.addChild("D:supportedlock")
	PropstatNode.AddChild("D:status", "HTTP/1.1 200 OK")
	
	'Print "Stat for a file:" + XMLTree.ToStringFormat(True)
	Return XMLTree.ToString()
End Function
