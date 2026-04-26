-- SetlistAutomations.applescript
-- This script contains event handlers triggered by the CloseEmbrace application.
-- It automatically manages track colors, playback gaps (minimum silence),
-- and effects bypassing based on the genres of the tracks in the setlist.

using terms from application "CloseEmbrace"
	
	-- =========================================================
	-- updateMinimumSilence
	-- =========================================================
	-- Helper subroutine to look ahead at the next track to adjust playback spacing.
	-- If the next track is a Cortina, it tightens the gap to 2 seconds.
	-- Otherwise, it restores the standard auto gap to 4 seconds.
	on updateMinimumSilence()
		tell application "CloseEmbrace"
			set curIdx to current index
			set totalTracks to count of tracks
			if curIdx < totalTracks then
				set nextTrack to item (curIdx + 1) of tracks
				if genre of nextTrack is "Cortina" then
					set minimum silence to 2
					display notification "Auto gap set to 2 seconds (Cortina upcoming)" with title "CloseEmbrace"
				else
					set minimum silence to 4
					display notification "Auto gap reset to 4 seconds" with title "CloseEmbrace"
				end if
			end if
		end tell
	end updateMinimumSilence
	
	-- =========================================================
	-- metadata available
	-- =========================================================
	-- Called immediately when CloseEmbrace finishes parsing a track's metadata.
	-- Responsibilities:
	-- 1. Apply color-coding to tracks based on genre (Cortina -> Red, Tango -> Blue, etc).
	-- 2. Trigger an updateMinimumSilence check if the newly parsed track is the immediate next track to play.
	on metadata available for t
		tell application "CloseEmbrace"
			set trackGenre to genre of t
			if trackGenre is "Cortina" then
				set label of t to red
			else if trackGenre is "Milonga" then
				set label of t to blue
			else if trackGenre is "Vals" then
				set label of t to green
			else
				set label of t to none
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
	
	-- =========================================================
	-- current track changed
	-- =========================================================
	-- Called whenever the application begins playing a new track or manually switches tracks.
	-- Responsibilities:
	-- 1. Automatically update the minimum silence for the upcoming transition based on the next track.
	-- 2. If a Cortina starts playing:
	--    a) Bypass any active audio effects for a clean sound.
	--    b) Spawn an independent background 80s countdown timer to automatically stop/fade the Cortina.
	-- 3. If a regular genre is playing, ensure audio effects are re-enabled.
	on current track changed
		tell application "CloseEmbrace"
			my updateMinimumSilence()
			
			if current track is not missing value then
				if genre of current track is "Cortina" then
					set bypassed of every effect to true
				else
					set bypassed of every effect to false
				end if
			end if
		end tell
	end current track changed
	
	-- =========================================================
	-- =========================================================
	-- setlist changed
	-- =========================================================
	-- Called whenever the application modifies the setlist (e.g., via drag and drop reordering, deletion).
	-- Additions are consciously bypassed by the native app to prevent duplicate triggering
	-- alongside the 'metadata available' handler.
	-- Responsibilities:
	-- 1. Ensure the gap is re-tuned if the next track order is changed.
	on setlist changed
		tell application "CloseEmbrace"
			my updateMinimumSilence()
		end tell
	end setlist changed
	
end using terms from
