--!strict
-- GovernmentArchetypes — classifies every government form into one of three
-- archetypes (monarchy / republic / tribal) plus a succession rule. The politics
-- systems and UI branch off these two keys (labels, dominant estates, succession,
-- event/rebellion flavor). Kept in a dedicated table rather than inline on
-- GovernmentTypes so the classification is centralized and additive — any form
-- missing here falls back to DEFAULT (monarchy / hereditary), so nothing breaks.

export type GovernmentArchetype = "monarchy" | "republic" | "tribal"
export type SuccessionKind = "hereditary" | "elective" | "republican_term" | "tribal_strongest"

local M = {}

M.DEFAULT = { archetype = "monarchy" :: GovernmentArchetype, successionKind = "hereditary" :: SuccessionKind }

-- archetype label sets (for UI: tab titles + Authority meter name)
M.labels = {
	monarchy = { authority = "Crown Authority", screen = "Court", estates = "Estates", leaderWord = "Ruler" },
	republic = { authority = "Republican Mandate", screen = "Senate", estates = "Factions", leaderWord = "Head of State" },
	tribal   = { authority = "Chiefly Authority", screen = "Council", estates = "Clans", leaderWord = "Chief" },
}

M.byGovernment = {
	absolute_monarchy       = { archetype = "monarchy", successionKind = "hereditary" },
	constitutional_monarchy = { archetype = "monarchy", successionKind = "hereditary" },
	parliamentary_monarchy  = { archetype = "monarchy", successionKind = "hereditary" },
	elective_monarchy       = { archetype = "monarchy", successionKind = "elective" },
	composite_monarchy      = { archetype = "monarchy", successionKind = "hereditary" },
	tsardom                 = { archetype = "monarchy", successionKind = "hereditary" },
	sultanate               = { archetype = "monarchy", successionKind = "hereditary" },
	caliphate               = { archetype = "monarchy", successionKind = "hereditary" },
	shogunate               = { archetype = "monarchy", successionKind = "hereditary" },
	imperial_bureaucracy    = { archetype = "monarchy", successionKind = "hereditary" },
	despotism               = { archetype = "monarchy", successionKind = "hereditary" },
	margravate              = { archetype = "monarchy", successionKind = "hereditary" },
	duchy                   = { archetype = "monarchy", successionKind = "hereditary" },
	county                  = { archetype = "monarchy", successionKind = "hereditary" },

	theocracy               = { archetype = "monarchy", successionKind = "elective" },
	prince_bishopric        = { archetype = "monarchy", successionKind = "elective" },
	ecclesiastical          = { archetype = "monarchy", successionKind = "elective" },

	merchant_republic       = { archetype = "republic", successionKind = "republican_term" },
	free_city               = { archetype = "republic", successionKind = "republican_term" },
	confederation           = { archetype = "republic", successionKind = "elective" },

	tribal_chiefdom         = { archetype = "tribal",   successionKind = "tribal_strongest" },
	khanate                 = { archetype = "tribal",   successionKind = "tribal_strongest" },
}

-- Resolve archetype/succession for a government id, always returning a valid def.
function M.get(governmentForm: string?): { archetype: GovernmentArchetype, successionKind: SuccessionKind }
	return (governmentForm and M.byGovernment[governmentForm]) or M.DEFAULT
end

function M.archetypeOf(governmentForm: string?): GovernmentArchetype
	return M.get(governmentForm).archetype
end

function M.labelsFor(governmentForm: string?)
	return M.labels[M.archetypeOf(governmentForm)] or M.labels.monarchy
end

return M
