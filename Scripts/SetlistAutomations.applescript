using terms from application "CloseEmbrace"
	
	on updateMinimumSilence()
		tell application "CloseEmbrace"
			set curIdx to current index
			set totalTracks to count of tracks
			if curIdx < totalTracks then
				set nextTrack to item (curIdx + 1) of tracks
				if genre of nextTrack is "Cortina" then
					set minimum silence to 2
					display notification "Minimum silence set to 2 seconds (Cortina upcoming)" with title "CloseEmbrace"
				else
					set minimum silence to 4
					display notification "Minimum silence set to 4 seconds" with title "CloseEmbrace"
				end if
			end if
		end tell
	end updateMinimumSilence

	on metadata available for t
		tell application "CloseEmbrace"
			set trackGenre to genre of t
			if trackGenre is "Cortina" then
				set label of t to red
			else if trackGenre is "Tango" then
				set label of t to blue
			else if trackGenre is "Vals" then
				set label of t to orange
			else if trackGenre is "Milonga" then
				set label of t to green
			end if
			
			set curIdx to current index
			set totalTracks to count of tracks
			if curIdx < totalTracks then
				set nextTrack to item (curIdx + 1) of tracks
				if id of t is id of nextTrack then
					my updateMinimumSilence()
				end if
			end if
		end tell
	end metadata available
	
	on current track changed
		tell application "CloseEmbrace"
			my updateMinimumSilence()
			
			if current track is not missing value then
				if genre of current track is "Cortina" then
					-- Run the non-blocking dialog in a background shell process
					do shell script "osascript -e '
						try
							tell application \"System Events\"
								activate
								set dlg to display dialog \"Cortina timer running. Stop in 80s?\" buttons {\"Cancel Timer\"} default button 1 giving up after 80
							end tell
							if gave up of dlg is true then
								tell application \"CloseEmbrace\" to stop
								delay 5
								tell application \"CloseEmbrace\" to play
							end if
						end try
					' > /dev/null 2>&1 &"
				end if
			end if
		end tell
	end current track changed
	
end using terms from
