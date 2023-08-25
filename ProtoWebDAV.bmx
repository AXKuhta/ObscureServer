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
	
	If ParsedRequest.PayloadSize
		Local Buffer:Byte[ParsedRequest.PayloadSize]
		
		Parameters.ClientStream.Read(Buffer, ParsedRequest.PayloadSize)
		RequestString = String.FromUTF8Bytes(Buffer, ParsedRequest.PayloadSize)

		' TODO: Handle the creation of collections (i.e. folders)
		' LoggedPrint("Client XML: " + RequestString)
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
		
	Local RootNode:TXMLTree = TXMLTree.NewTree("D:multistatus", "", " xmlns:D=~qDAV:~q")
	
	Local ResponseNode:TXMLTree
	Local PropstatNode:TXMLTree
	Local PropNode:TXMLTree
	
	' A special entry for currently opened folder
	ResponseNode = RootNode.AddChild("D:response")
	If DirectoryPath = "."
		ResponseNode.AddChild("D:href", "/") ' Href is at root
	Else
		ResponseNode.AddChild("D:href", Mid(DirectoryPath, 2) + "/") ' Href is within a subfolder
	End If
	PropstatNode = ResponseNode.AddChild("D:propstat")
	PropNode = PropstatNode.AddChild("D:prop")
	PropNode.AddChild("D:resourcetype").AddChild("D:collection")
	PropNode.AddChild("D:displayname", "") ' But the name is empty
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
		
		ResponseNode = RootNode.AddChild("D:response")
		ResponseNode.AddChild("D:href", Right(EntryPath, Len(EntryPath) - 1)) ' Will trim the dot on the left
		
		PropstatNode = ResponseNode.addChild("D:propstat")
		PropNode = PropstatNode.addChild("D:prop")

		
		Select FileType(EntryPath)
			Case 0
				Print "WebDAV: Unable to stat file: " + EntryPath 
			Case 1
				PropNode.AddChild("D:creationdate")
				PropNode.AddChild("D:displayname", StripDir(EntryPath))
				PropNode.AddChild("D:getcontentlength", FileSize(EntryPath))
				PropNode.AddChild("D:getcontenttype")
				PropNode.AddChild("D:getetag")
				PropNode.AddChild("D:getlastmodified", GetHTTPTime(FileTime(EntryPath)))
				PropNode.AddChild("D:resourcetype")
				PropNode.AddChild("D:supportedlock")
			Case 2
				PropNode.AddChild("D:creationdate")
				PropNode.AddChild("D:displayname", StripDir(EntryPath))
				PropNode.AddChild("D:resourcetype").AddChild("D:collection")
				PropNode.AddChild("D:supportedlock")
		End Select
		
		PropstatNode.AddChild("D:status", "HTTP/1.1 200 OK")
	Forever
	
	'Print "Directory listing: " + RootNode.TransformIntoText()
	Return RootNode.TransformIntoText()
End Function

Function BuildXMLFileStat:String(FilePath:String)
	Local RootNode:TXMLTree = TXMLTree.NewTree("D:multistatus", "", " xmlns:D=~qDAV:~q")
	
	Local ResponseNode:TXMLTree
	Local PropstatNode:TXMLTree
	Local PropNode:TXMLTree
	
	ResponseNode = RootNode.AddChild("D:response")
	ResponseNode.AddChild("D:href", "/" + FilePath)
	PropstatNode = ResponseNode.AddChild("D:propstat")
	PropNode = PropstatNode.AddChild("D:prop")
	PropNode.AddChild("D:creationdate")
	PropNode.AddChild("D:displayname", StripDir(FilePath))
	PropNode.AddChild("D:getcontentlength", FileSize(FilePath))
	PropNode.AddChild("D:getcontenttype")
	PropNode.AddChild("D:getetag")
	PropNode.AddChild("D:getlastmodified", GetHTTPTime(FileTime(FilePath)))
	PropNode.AddChild("D:resourcetype")
	PropNode.AddChild("D:supportedlock")
	PropstatNode.AddChild("D:status", "HTTP/1.1 200 OK")
	
	'Print "Stat for a file:" + RootNode.TransformIntoText()
	Return RootNode.TransformIntoText()
End Function


' Minimalistic XML builder
Type TXMLTree
	' Data
	Field Name:String
	Field Value:String
	Field Version:String ' Populated only for the root node
	Field Attributes:String

	' Structure
	Field Parent:TXMLTree
	
	Field FirstChild:TXMLTree ' Stays null most of the time
	Field LastChild:TXMLTree ' Stays null most of the time
	
	Field NextNode:TXMLTree
	
	' Functions
	Function NewTree:TXMLTree(Name:String, Value:String = "", Attributes:String = "")
		Local NewTree:TXMLTree = New TXMLTree
		
		NewTree.Name = Name
		NewTree.Value = Value
		NewTree.Version = "<?xml version=~q1.0~q encoding=~qutf-8~q?>"
		NewTree.Attributes = Attributes

		Return NewTree
	End Function
	
	Method AddChild:TXMLTree(Name:String, Value:String = "", Attributes:String = "")
		Local NewNode:TXMLTree = New TXMLTree
		
		NewNode.Name = Name
		NewNode.Value = Value
		NewNode.Attributes = Attributes
		
		NewNode.Parent = Self
		
		
		' One-way linked list generation
		If FirstChild = Null
			FirstChild = NewNode
			LastChild = NewNode
		Else
			LastChild.NextNode = NewNode
			LastChild = NewNode
		End If
		
		Return NewNode
	End Method
		
	Method TransformIntoText:String()
		Local Result:String = ""
		
		' Include the version string on a root node
		If Parent = Null
			Result :+ Version
		End If
		
		' Check if the node is empty and use the short code path if so
		' Otherwise go for the iterating code path
		If Value = "" And FirstChild = Null
			Result :+ "<"+Name+Attributes+" />"
		Else
			Result :+ "<"+Name+Attributes+">"
			Result :+ Value
			
			' Recursively go through children
			Local Node:TXMLTree = FirstChild
			
			While Node <> Null
				Result :+ Node.TransformIntoText()
				
				Node = Node.NextNode
			Wend
			
			Result :+ "</"+Name+">"
		End If
		
		Return Result
	End Method
End Type
