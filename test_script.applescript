do shell script "osascript -e '
try
    tell application \"System Events\"
        set dlg to display dialog \"Cortina timer running. Stop in 80s?\" buttons {\"Cancel Timer\"} default button 1 giving up after 80
    end tell
    if gave up of dlg is true then
        tell application \"CloseEmbrace\" to stop
        delay 5
        tell application \"CloseEmbrace\" to play
    end if
end try
' > /dev/null 2>&1 &"
