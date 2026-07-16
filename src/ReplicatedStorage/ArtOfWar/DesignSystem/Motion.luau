local Players = game:GetService("Players")

local Motion = {}

-- Whether this player has asked for reduced motion (Settings -> Display & Sound). The attribute is absent by
-- default, so motion is FULL unless a player turns it on. Mirrors Tooltip.enabled(): it MUST be read when an
-- animation FIRES rather than when the UI is wired up, so the toggle takes effect live without a rebuild.
-- Every animated surface consults this -- the Animations.tween chokepoint, the HUD alert pulse and the army
-- selection pulse -- so the name of the attribute lives in exactly one place.
function Motion.reduced()
	local lp = Players.LocalPlayer
	return lp ~= nil and lp:GetAttribute("ReduceMotion") == true
end

return Motion
