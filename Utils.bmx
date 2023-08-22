Framework BRL.StandardIO
Import BRL.System
Import BRL.Retro
Import "Parameters.bmx"
Import "microseconds.c"
Import "http_time.c"

Extern
	Function microseconds:ULong()
	Function http_time:Int(memory:Byte Ptr, epoch_time:ULong)
	Function strlen:Size_T(memory:Byte Ptr)
End Extern


Function LoggedPrint(ToPrint:String)
	Local ConnectionID:ULong = get_thread_parameters().ConnectionID

	Print "[" + CurrentDate() + " " + CurrentTime() + "][ConnectionID: " + ConnectionID + "] " + ToPrint
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

' Converts "ff" or "FF" to 255
' Or "A5" to 165 
Function HexToDec8:Byte(Inp:String)
	Local LUT:Byte[] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 0, 0, 0, 0, 0, 0, $A, $B, $C, $D, $E, $F, ..
						0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, ..
						$A, $B, $C, $D, $E, $F]
									
	Return (LUT[Inp[0] - 48] Shl 4) | LUT[Inp[1] - 48]
End Function

' Alternative version under the same name that takes two "chars" instead of a string
Function HexToDec8:Byte(First:Int, Second:Int)
	Local LUT:Byte[] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 0, 0, 0, 0, 0, 0, $A, $B, $C, $D, $E, $F, ..
						0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, ..
						$A, $B, $C, $D, $E, $F]
									
	Return (LUT[First - 48] Shl 4) | LUT[Second - 48]
End Function


Function URLDecode:String(Inp:String)
	If Not Instr(Inp, "%") Then Return Inp ' No action required if no %'s found
	
	Local DecodedLine:String
	Local StartPosition:Int = 0
	
	Local InpLen:Size_T = Len(Inp)
	
	Local iInp:Int = 0
	Local iOut:Int = 0
	
	Local RawDecodedLine:Byte Ptr = MemAlloc(InpLen)
	
	While iInp < InpLen
		' 37 is "%"
		If Inp[iInp] = 37 
			If iInp + 2 >= InpLen Then Exit
			
			RawDecodedLine[iOut] = HexToDec8(Inp[iInp + 1], Inp[iInp + 2])
			iInp :+ 3
			iOut :+ 1
		Else
			RawDecodedLine[iOut] = Inp[iInp]
			iInp :+ 1
			iOut :+ 1
		End If
	Wend 
	
	' Make sure to insert the null-terminator at the end
	RawDecodedLine[iOut] = 0
		
	DecodedLine = String.FromUTF8String(RawDecodedLine)
	
	MemFree(RawDecodedLine)
	
	Return DecodedLine	
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


Function GetKiloseconds:String(ms:Long)
	Local Unit:String
	Local Time:String
	
	If ms < 1000
		Time = ms
		Unit = "ms"
	ElseIf ms < 1000 * 1000
		Time = ms / 10
		Unit = "seconds"
	ElseIf ms < 1000 * 1000 * 1000
		Time = ms / 1000 / 10
		Unit = "kiloseconds"
	ElseIf ms < 1000 * 1000 * 1000 * 1000
		Time = ms / 1000 / 1000 / 10
		Unit = "megaseconds"
	Else
		Time = ms / 1000 / 1000 / 1000 / 10
		Unit = "gigaseconds"
	End If
	
	' Insert a point before the two rightmost digits
	Time = Left(Time, Len(Time) - 2) + "." + Right(Time, 2)
		
	Return Time + " " + Unit
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
