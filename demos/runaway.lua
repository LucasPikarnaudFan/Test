-- runaway.lua — an infinite loop. The instruction watchdog must kill it
-- instead of freezing the frame. Loaded on purpose by the demo.
local n = 0
while true do n = n + 1 end
