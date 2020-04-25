Framework BRL.StandardIO
Import BRL.System
Import BRL.Retro
Import "microseconds.c"
Import "http_time.c"

Extern
	Function microseconds:ULong()
	Function http_time:Int(memory:Byte Ptr, epoch_time:ULong)
	Function strlen:Size_T(memory:Byte Ptr)
End Extern


Function LoggedPrint(ToPrint:String, ThreadID:ULong = 0)
	Print "[" + CurrentDate() + " " + CurrentTime() + "][ThreadID: " + ThreadID + "] " + ToPrint
End Function


Function IsInArray:Int(Target:String, Array:String[])
	For Local i:String = EachIn Array
		If Target = i Then Return 1
	Next
	
	Return 0
End Function


Function PrintArray(Array:String[])
	For Local i=0 To (Array.length - 1)
		Print "["+i+"] " + Array[i]
	Next
End Function


Function ReadBytes:Byte[](Stream:TStream, Length:Int)
	Local RetArray:Byte[]
	
	If Length = 0 Then Print "Error: ReadBytes called with Length = 0. Aborting." ; Return Null
	
	For Local i=0 To (Length - 1)
		RetArray = RetArray[..(i+1)]
		RetArray[i] = ReadByte(Stream)
	Next
		
	Return RetArray
End Function


Function HexToDec8:Byte(Inp:String)
	Local AsciiToHexTable:Byte[] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 0, 0, 0, 0, 0, 0, $A, $B, $C, $D, $E, $F, ..
									0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, ..
									$A, $B, $C, $D, $E, $F]
									
	Local ASCIIArray:Byte Ptr = Inp.toCString()
	Local ReturnValue:Byte = (AsciiToHexTable[ASCIIArray[0] - 48] Shl 4) | AsciiToHexTable[ASCIIArray[1] - 48]
	
	MemFree(ASCIIArray)
	
	Return ReturnValue
End Function


Function NormifySpaces:String(Inp:String)	
	Local NormifiedLine:String
	Local InstrStartPosition:Int = 1
	
	If Instr(Inp, "%", InstrStartPosition) = 0 Then Return Inp ' Not changes required if no %s found
	
	While Instr(Inp, "%", InstrStartPosition) <> 0
		NormifiedLine = NormifiedLine + Mid(Inp, InstrStartPosition, (Instr(Inp, "%", InstrStartPosition) - InstrStartPosition))
		NormifiedLine = NormifiedLine + Chr(HexToDec8(Mid(Inp, Instr(Inp, "%", InstrStartPosition) + 1, 2)))
		
		'Print "Adding char: " + HexToDec(Mid(Inp, Instr(Inp, "%", InstrStartPosition) + 1, 2))
		
		InstrStartPosition = Instr(Inp, "%", InstrStartPosition) + 3
	Wend
	
	NormifiedLine = NormifiedLine + Mid(Inp, InstrStartPosition, (Len(Inp) - InstrStartPosition) + 1)
	
	Return NormifiedLine	
End Function

' This function will generate a completely random string
' It will generate only standard ASCII letters, no special symbols
Function GenerateRandomString:String(Length:Int)
	Local Memory:Byte Ptr = MemAlloc(Size_T(Length))
	Local Result:String
	
	For Local i=0 To (Length - 1)
		Memory[i] = Rnd(94) + 33
	Next
	
	Result = String.FromBytes(Memory, Length)
	MemFree(Memory)
	Return Result
End Function

' This function converts time produced by functions like FileTime() into an HTTP-compliant human readable string
' Keep in mind that it also converts to GMT/UTC from local time
Function GetHTTPTime:String(EpochTime:Int)
	Local RawString:Byte Ptr = MemAlloc(128)
	Local Result:String
	
	If http_time(RawString, ULong(EpochTime)) > 0
		Result = String.FromCString(RawString)
	Else
		Result = "Time conversion error"
	End If
		
	MemFree(RawString)
	
	Return Result
End Function
