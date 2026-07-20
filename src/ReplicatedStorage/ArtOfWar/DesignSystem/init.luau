local DesignSystem = {}

-- WaitForChild (not direct-index) so requiring DesignSystem on the CLIENT reliably waits for each child
-- ModuleScript to replicate instead of erroring when one is still in flight. Consumers should require this
-- aggregator and read e.g. DesignSystem.Motion -- the require'd value is cached and survives any later
-- instance churn, unlike a per-consumer WaitForChild on the child instance (which can infinite-yield and
-- stall the whole client boot; see ArmyView).
DesignSystem.Colors = require(script:WaitForChild("Colors"))
DesignSystem.Typography = require(script:WaitForChild("Typography"))
DesignSystem.Spacing = require(script:WaitForChild("Spacing"))
DesignSystem.Animations = require(script:WaitForChild("Animations"))
DesignSystem.Motion = require(script:WaitForChild("Motion"))
DesignSystem.Icons = require(script:WaitForChild("Icons"))
DesignSystem.Responsive = require(script:WaitForChild("Responsive"))
DesignSystem.Shells = require(script:WaitForChild("Shells"))

return DesignSystem
