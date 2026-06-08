local DoctrineSlots = {
	base = {
		id = "base",
		tier = 1,
		displayName = "Base Doctrine",
		description = "The foundational stance: will our army be professional volunteers or a conscripted levy?",
		order = 1,
		baseSwitchCost = 40,
	},
	infantry = {
		id = "infantry",
		tier = 2,
		displayName = "Infantry Doctrine",
		description = "How the line fights — massed volley, loose skirmish, or irregular partisan.",
		order = 2,
		baseSwitchCost = 55,
	},
	artillery = {
		id = "artillery",
		tier = 2,
		displayName = "Artillery Doctrine",
		description = "Mass the guns or spread them among the battalions.",
		order = 3,
		baseSwitchCost = 55,
	},
	cavalry = {
		id = "cavalry",
		tier = 2,
		displayName = "Cavalry Doctrine",
		description = "Shock at the charge or speed at the screen.",
		order = 4,
		baseSwitchCost = 55,
	},
	advanced = {
		id = "advanced",
		tier = 3,
		displayName = "Advanced Doctrine",
		description = "Reserved for campaign tech unlocks.",
		order = 5,
		baseSwitchCost = 90,
		unlockedByDefault = false,
	},
}

for id, def in DoctrineSlots do
	def.id = id
end

return DoctrineSlots
