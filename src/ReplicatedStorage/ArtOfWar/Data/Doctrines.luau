local Doctrines = {
	professional_army = {
		id = "professional_army",
		tier = 1,
		slot = "base",
		displayName = "Professional Army Focus",
		description = "Maintain a standing force of long-service volunteers drilled to the parade-ground standard of Potsdam and Versailles.",
		modifiers = {
			army_training_speed = 0.50,
			army_upkeep = 0.25,
			army_starting_experience = 0.25,
			army_manpower_pool = -0.10,
		},
	},

	conscripted_army = {
		id = "conscripted_army",
		tier = 1,
		slot = "base",
		displayName = "Conscripted Army Focus",
		description = "Levy from the provinces. Cheaper to field, but raw regiments arrive with little beyond enthusiasm.",
		modifiers = {
			army_training_speed = -0.20,
			army_upkeep = -0.25,
			army_starting_experience = -0.50,
			army_manpower_pool = 0.20,
		},
	},

	line_infantry_formation = {
		id = "line_infantry_formation",
		tier = 2,
		slot = "infantry",
		displayName = "Line Infantry Formation",
		description = "Three ranks, measured volleys. The accepted grammar of European war — Frederick, Saxe, and Washington's continentals all spoke it.",
		modifiers = {
			army_defense = 0.20,
			army_attack = -0.20,
			army_organization = 10.0,
		},
	},

	dispersed_infantry_formation = {
		id = "dispersed_infantry_formation",
		tier = 2,
		slot = "infantry",
		displayName = "Dispersed Infantry Formation",
		description = "Open order, aimed fire. Jäger and American rifles show how looser files can cover more ground and pick their targets.",
		modifiers = {
			army_defense = -0.20,
			army_attack = 0.20,
			army_movement_speed = 0.12,
			army_occupation_speed = 0.25,
			army_organization = 7.5,
		},
	},

	asymmetrical_infantry_formation = {
		id = "asymmetrical_infantry_formation",
		tier = 2,
		slot = "infantry",
		displayName = "Asymmetrical Infantry Formation",
		description = "Against a stronger foe, fight on your own ground. Hussite wagenburgs, Balkan klephts, Carolina partisans — bleed the line, do not meet it.",
		modifiers = {
			army_attack = 0.10,
			army_defense = 0.05,
			army_organization = 5.0,
			army_attrition_enemy = 0.15,
			army_terrain_specialization = 0.05,
		},
	},

	concentrated_artillery = {
		id = "concentrated_artillery",
		tier = 2,
		slot = "artillery",
		displayName = "Concentrated Artillery Focus",
		description = "Mass the guns. Frederick's grand battery at Leuthen and Bonaparte at Lodi taught Europe the arithmetic of focused fire.",
		modifiers = {
			army_organization = 1.5,
			army_fort_assault = 0.20,
			army_attack = 0.08,
		},
	},

	dispersed_artillery = {
		id = "dispersed_artillery",
		tier = 2,
		slot = "artillery",
		displayName = "Dispersed Artillery Focus",
		description = "Guns on every hill. Battalion pieces at hand mean the line is never out of powder when the enemy closes.",
		modifiers = {
			army_organization = 1.0,
			army_attack = 0.15,
			army_defense = 0.15,
		},
	},

	heavy_cavalry = {
		id = "heavy_cavalry",
		tier = 2,
		slot = "cavalry",
		displayName = "Heavy Cavalry Focus",
		description = "Cuirassiers and carabiniers — expensive horse, heavy sabre, shock at the close of battle.",
		modifiers = {
			army_attack = 0.12,
			army_movement_speed = 0.06,
			army_upkeep = 0.10,
			army_cavalry_shock = 0.25,
		},
	},

	light_cavalry = {
		id = "light_cavalry",
		tier = 2,
		slot = "cavalry",
		displayName = "Light Cavalry Focus",
		description = "Hussars and chasseurs. Screen the march, harry the supply trains, know the country before the enemy does.",
		modifiers = {
			army_movement_speed = 0.15,
			army_occupation_speed = 0.10,
			army_attrition_enemy = 0.10,
			army_attack = 0.04,
		},
	},
}

for id, def in Doctrines do
	def.id = id
end

return Doctrines
