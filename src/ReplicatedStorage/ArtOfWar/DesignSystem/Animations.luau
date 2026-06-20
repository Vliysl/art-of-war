local TweenService = game:GetService("TweenService")

local Animations = {}

Animations.Default = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
Animations.Fast = TweenInfo.new(0.10, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
Animations.Slow = TweenInfo.new(0.30, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
Animations.ModalIn = TweenInfo.new(0.20, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

function Animations.tween(instance, info, properties)
	local tween = TweenService:Create(instance, info or Animations.Default, properties)
	tween:Play()
	return tween
end

return Animations
