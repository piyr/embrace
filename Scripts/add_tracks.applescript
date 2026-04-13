#!/usr/bin/osascript
-- add_tracks.applescript
-- Usage: ./add_tracks.applescript [file1.mp3] [../other/song.FLAC] [playlist.m3u] ...

on run argv
	if (count of argv) is 0 then
		log "Usage: ./add_tracks.applescript <audio file | .m3u/.m3u8 playlist path> ..."
		return
	end if
	
	set fileList to {}
	repeat with arg in argv
		-- Expand relative paths and perfectly parse m3u/m3u8 playlists using embedded Python
		set pathsRaw to do shell script "python3 -c '
import os, sys
arg = sys.argv[1]
abs_arg = os.path.abspath(arg)
if arg.lower().endswith(\".m3u\") or arg.lower().endswith(\".m3u8\"):
    with open(abs_arg, \"r\", encoding=\"utf-8\") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith(\"#\"):
                print(os.path.abspath(os.path.join(os.path.dirname(abs_arg), line)))
else:
    print(abs_arg)
' " & quoted form of arg
		
		-- AppleScript splits print statements gracefully into paragraphs
		repeat with p in paragraphs of pathsRaw
			if length of p > 0 then
				set end of fileList to (POSIX file p)
			end if
		end repeat
	end repeat
	
	-- Due to AppDelegate.m's 'application:openFiles:' reversed enumeration behavior 
	-- when receiving generic files from LaunchServices, we must reverse our payload
	-- before sending it so it successfully cancels out and plays chronologically!
	set reversedFileList to {}
	repeat with i from (count of fileList) to 1 by -1
		set end of reversedFileList to item i of fileList
	end repeat
	
	tell application "CloseEmbrace"
		open reversedFileList
	end tell
	
	log "Successfully queued " & (count of fileList) & " tracks to CloseEmbrace!"
end run
