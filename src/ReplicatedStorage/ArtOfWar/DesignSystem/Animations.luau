local TweenService = game:GetService("TweenService")

local Motion = require(script.Parent.Motion)

local Animations = {}

Animations.Default = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
Animations.Fast = TweenInfo.new(0.10, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
Animations.Slow = TweenInfo.new(0.30, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
Animations.ModalIn = TweenInfo.new(0.20, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

function Animations.tween(instance, info, properties)
	-- Reduced motion: snap straight to the end state instead of animating (prefers-reduced-motion semantics).
	-- Every UI transition funnels through here, so gating this one spot covers button/tab/modal/notification/
	-- progress-bar motion at once. Read live via Motion.reduced() so the Settings toggle takes effect at once.
	if Motion.reduced() then
		for prop, value in properties do
			instance[prop] = value
		end
		return
	end
	local tween = TweenService:Create(instance, info or Animations.Default, properties)
	tween:Play()
	return tween
end

return Animations
