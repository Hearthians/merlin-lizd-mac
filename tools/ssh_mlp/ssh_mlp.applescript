on open inputFiles
	repeat with inputFile in inputFiles
		set inputPath to POSIX path of inputFile
		set logPath to POSIX path of (path to home folder) & "Library/Logs/ssh_mlp-launcher.log"
		set toolPath to POSIX path of (path to home folder) & ".local/bin/ssh_mlp"
		do shell script quoted form of toolPath & " " & quoted form of inputPath & " >> " & quoted form of logPath & " 2>&1 &"
	end repeat
end open

on run
	set logPath to POSIX path of (path to home folder) & "Library/Logs/ssh_mlp-launcher.log"
	set toolPath to POSIX path of (path to home folder) & ".local/bin/ssh_mlp"
	do shell script quoted form of toolPath & " --configure >> " & quoted form of logPath & " 2>&1 &"
end run
