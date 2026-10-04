# Timing

One enabled clock advances the round-robin slot from T0 through T3. A running slot executes at most one instruction per four enabled clocks. A wait instruction parks only the selected slot; its counter decrements on that slot's subsequent grants. Reset is asynchronous active-low at the top-level wrapper. No absolute-deadline timing unit is connected in the current integration.
